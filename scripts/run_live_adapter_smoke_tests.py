#!/usr/bin/env python3
"""Run live dbt adapter smoke tests for Semantic Rails contract checks."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import yaml
except ModuleNotFoundError:
    yaml = None  # type: ignore[assignment]


TAIL_CHARS = 12000


@dataclass(frozen=True)
class AdapterConfig:
    name: str
    package: str
    required_env: tuple[str, ...]
    profile: dict[str, Any]
    probe_sql: str
    column_types: dict[str, str]


def env_var(name: str) -> str:
    return "{{ env_var('" + name + "') }}"


ADAPTERS: dict[str, AdapterConfig] = {
    "athena": AdapterConfig(
        name="athena",
        package="dbt-athena",
        required_env=("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION", "SR_ATHENA_DATABASE", "SR_ATHENA_S3_STAGING_DIR"),
        profile={
            "type": "athena",
            "s3_staging_dir": env_var("SR_ATHENA_S3_STAGING_DIR"),
            "s3_data_dir": env_var("SR_ATHENA_S3_DATA_DIR"),
            "s3_data_naming": "schema_table_unique",
            "region_name": env_var("AWS_REGION"),
            "database": "awsdatacatalog",
            "schema": env_var("SR_ATHENA_DATABASE"),
            "threads": 1,
            "num_retries": 2,
        },
        probe_sql="select cast(1 as integer) as probe_id, cast('semantic_rails' as varchar) as probe_name",
        column_types={"probe_id": "integer", "probe_name": "varchar"},
    ),
    "bigquery": AdapterConfig(
        name="bigquery",
        package="dbt-bigquery",
        required_env=("GOOGLE_APPLICATION_CREDENTIALS", "SR_BIGQUERY_PROJECT", "SR_BIGQUERY_DATASET"),
        profile={
            "type": "bigquery",
            "method": "service-account",
            "project": env_var("SR_BIGQUERY_PROJECT"),
            "dataset": env_var("SR_BIGQUERY_DATASET"),
            "keyfile": env_var("GOOGLE_APPLICATION_CREDENTIALS"),
            "threads": 1,
            "job_execution_timeout_seconds": 120,
            "job_retries": 1,
        },
        probe_sql="select cast(1 as int64) as probe_id, cast('semantic_rails' as string) as probe_name",
        column_types={"probe_id": "int64", "probe_name": "string"},
    ),
    "databricks": AdapterConfig(
        name="databricks",
        package="dbt-databricks",
        required_env=("SR_DATABRICKS_HOST", "SR_DATABRICKS_HTTP_PATH", "SR_DATABRICKS_TOKEN", "SR_DATABRICKS_CATALOG", "SR_DATABRICKS_SCHEMA"),
        profile={
            "type": "databricks",
            "host": env_var("SR_DATABRICKS_HOST"),
            "http_path": env_var("SR_DATABRICKS_HTTP_PATH"),
            "token": env_var("SR_DATABRICKS_TOKEN"),
            "catalog": env_var("SR_DATABRICKS_CATALOG"),
            "schema": env_var("SR_DATABRICKS_SCHEMA"),
            "threads": 1,
        },
        probe_sql="select cast(1 as bigint) as probe_id, cast('semantic_rails' as string) as probe_name",
        column_types={"probe_id": "bigint", "probe_name": "string"},
    ),
    "motherduck": AdapterConfig(
        name="motherduck",
        package="dbt-duckdb",
        required_env=("SR_MOTHERDUCK_TOKEN",),
        profile={
            "type": "duckdb",
            "path": "md:semantic_rails_contracts_live?motherduck_token=" + env_var("SR_MOTHERDUCK_TOKEN"),
            "threads": 1,
        },
        probe_sql="select cast(1 as integer) as probe_id, cast('semantic_rails' as varchar) as probe_name",
        column_types={"probe_id": "integer", "probe_name": "varchar"},
    ),
    "redshift": AdapterConfig(
        name="redshift",
        package="dbt-redshift",
        required_env=("SR_REDSHIFT_HOST", "SR_REDSHIFT_PORT", "SR_REDSHIFT_DATABASE", "SR_REDSHIFT_USER", "SR_REDSHIFT_PASSWORD"),
        profile={
            "type": "redshift",
            "host": env_var("SR_REDSHIFT_HOST"),
            "port": "{{ env_var('SR_REDSHIFT_PORT') | int }}",
            "dbname": env_var("SR_REDSHIFT_DATABASE"),
            "user": env_var("SR_REDSHIFT_USER"),
            "password": env_var("SR_REDSHIFT_PASSWORD"),
            "schema": "semantic_rails_contracts_live",
            "threads": 1,
        },
        probe_sql="select cast(1 as integer) as probe_id, cast('semantic_rails' as varchar) as probe_name",
        column_types={"probe_id": "integer", "probe_name": "varchar"},
    ),
    "snowflake": AdapterConfig(
        name="snowflake",
        package="dbt-snowflake",
        required_env=("SR_SNOWFLAKE_ACCOUNT", "SR_SNOWFLAKE_USER", "SR_SNOWFLAKE_PASSWORD", "SR_SNOWFLAKE_DATABASE", "SR_SNOWFLAKE_WAREHOUSE", "SR_SNOWFLAKE_SCHEMA"),
        profile={
            "type": "snowflake",
            "account": env_var("SR_SNOWFLAKE_ACCOUNT"),
            "user": env_var("SR_SNOWFLAKE_USER"),
            "password": env_var("SR_SNOWFLAKE_PASSWORD"),
            "database": env_var("SR_SNOWFLAKE_DATABASE"),
            "warehouse": env_var("SR_SNOWFLAKE_WAREHOUSE"),
            "schema": env_var("SR_SNOWFLAKE_SCHEMA"),
            "threads": 1,
            "client_session_keep_alive": False,
        },
        probe_sql="select cast(1 as number) as probe_id, cast('semantic_rails' as varchar) as probe_name",
        column_types={"probe_id": "number", "probe_name": "varchar"},
    ),
}


def parse_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        raise SystemExit(f"{path} does not exist")
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key:
            continue
        try:
            parsed = shlex.split(value, posix=True)
            out[key] = parsed[0] if parsed else ""
        except ValueError:
            out[key] = value.strip().strip("'\"")
    return out


def load_environment(env_file: str | None) -> dict[str, str]:
    env = os.environ.copy()
    if env_file:
        env.update(parse_env_file(Path(env_file).expanduser()))
    if env.get("SR_ATHENA_S3_STAGING_DIR") and not env.get("SR_ATHENA_S3_DATA_DIR"):
        env["SR_ATHENA_S3_DATA_DIR"] = env["SR_ATHENA_S3_STAGING_DIR"].rstrip("/") + "/dbt-live-data/"
    if env.get("SR_MOTHERDUCK_TOKEN") and not env.get("motherduck_token"):
        env["motherduck_token"] = env["SR_MOTHERDUCK_TOKEN"]
    return env


def tail(value: str) -> str:
    if len(value) <= TAIL_CHARS:
        return value
    return value[-TAIL_CHARS:]


def redact(value: str, env: dict[str, str]) -> str:
    redacted = value
    for key, secret in env.items():
        if any(marker in key.upper() for marker in ("KEY", "TOKEN", "PASSWORD", "SECRET", "CREDENTIAL")) and secret:
            redacted = redacted.replace(secret, "<redacted>")
    return redacted


def command_record(argv: list[str], cwd: Path, env: dict[str, str], timeout_seconds: int) -> dict[str, Any]:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            argv,
            cwd=str(cwd),
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout_seconds,
            check=False,
        )
        return {
            "argv": argv,
            "returncode": completed.returncode,
            "duration_seconds": round(time.monotonic() - started, 3),
            "stdout_tail": tail(redact(completed.stdout, env)),
            "stderr_tail": tail(redact(completed.stderr, env)),
        }
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
        return {
            "argv": argv,
            "returncode": 124,
            "duration_seconds": round(time.monotonic() - started, 3),
            "stdout_tail": tail(redact(stdout, env)),
            "stderr_tail": tail(redact((stderr + f"\nTimed out after {timeout_seconds} seconds.").strip(), env)),
        }


def available(adapter: AdapterConfig, env: dict[str, str]) -> tuple[bool, list[str]]:
    missing = [name for name in adapter.required_env if not env.get(name)]
    if adapter.name == "bigquery" and env.get("GOOGLE_APPLICATION_CREDENTIALS"):
        keyfile = Path(env["GOOGLE_APPLICATION_CREDENTIALS"]).expanduser()
        if not keyfile.exists():
            missing.append("GOOGLE_APPLICATION_CREDENTIALS:file")
    return (len(missing) == 0, missing)


def write_project(root: Path, package_root: Path, adapter: AdapterConfig) -> None:
    if yaml is None:
        raise SystemExit("PyYAML is required. Install requirements-dev.txt or run with uv.")
    if root.exists():
        shutil.rmtree(root)
    (root / "models").mkdir(parents=True)
    (root / "macros").mkdir(parents=True)

    project_name = f"semantic_rails_live_{adapter.name}"
    profile_name = project_name
    local_package_path = os.path.relpath(package_root, root)
    contract = {
        "semantic_rails_contracts": {
            "contract_format_version": 1,
            "semantic": {
                "producer": {"name": "semantic-rails", "version": "0.2.0"},
                "packages": [
                    {
                        "package_id": f"live_{adapter.name}",
                        "namespace": adapter.name,
                        "package_schema_version": 1,
                        "semantic_hash": f"sha256:live-{adapter.name}",
                        "resources": [
                            {
                                "semantic_model_id": "live_probe",
                                "relation": "live_probe",
                                "columns": [{"name": "probe_id"}, {"name": "probe_name"}],
                            }
                        ],
                    }
                ],
            },
            "binding": {
                "kind": "dbt",
                "binding_version": 1,
                "packages": [
                    {
                        "package_id": f"live_{adapter.name}",
                        "policy": {
                            "severity": "error",
                            "require_model_contract": True,
                            "require_model_version": True,
                            "type_check": "ignore",
                            "allow_extra_columns": True,
                        },
                        "resources": [
                            {
                                "semantic_model_id": "live_probe",
                                "dbt_resource_type": "model",
                                "dbt_model": "live_probe",
                                "dbt_package": project_name,
                                "dbt_version": 1,
                                "latest_version": 1,
                                "access": "public",
                                "contract_enforced": True,
                            }
                        ],
                    }
                ],
            },
        }
    }

    dbt_project = {
        "name": project_name,
        "version": "1.0.0",
        "config-version": 2,
        "profile": profile_name,
        "model-paths": ["models"],
        "macro-paths": ["macros"],
        "clean-targets": ["target", "dbt_packages", "logs"],
        "require-dbt-version": [">=1.11.2", "<2.0.0"],
        "vars": contract,
    }
    profiles = {profile_name: {"target": "live", "outputs": {"live": adapter.profile}}}
    model_schema = {
        "version": 2,
        "models": [
            {
                "name": "live_probe",
                "access": "public",
                "latest_version": 1,
                "config": {"materialized": "table", "contract": {"enforced": True}},
                "columns": [
                    {"name": "probe_id", "data_type": adapter.column_types["probe_id"]},
                    {"name": "probe_name", "data_type": adapter.column_types["probe_name"]},
                ],
                "versions": [{"v": 1}],
            }
        ],
    }

    (root / "dbt_project.yml").write_text(yaml.safe_dump(dbt_project, sort_keys=False), encoding="utf-8")
    (root / "profiles.yml").write_text(yaml.safe_dump(profiles, sort_keys=False), encoding="utf-8")
    (root / "packages.yml").write_text(yaml.safe_dump({"packages": [{"local": local_package_path}]}, sort_keys=False), encoding="utf-8")
    (root / "models" / "live_probe_v1.sql").write_text(adapter.probe_sql + "\n", encoding="utf-8")
    (root / "models" / "schema.yml").write_text(yaml.safe_dump(model_schema, sort_keys=False), encoding="utf-8")
    (root / "macros" / "cleanup_live_probe.sql").write_text(
        """{% macro cleanup_live_probe() %}
  {% set relation = adapter.get_relation(database=target.database, schema=target.schema, identifier='live_probe_v1') %}
  {% if relation is not none %}
    {% do adapter.drop_relation(relation) %}
  {% endif %}
{% endmacro %}
""",
        encoding="utf-8",
    )


def dbt_command(adapter: AdapterConfig) -> list[str]:
    base = os.environ.get("DBT_LIVE_COMMAND")
    if base:
        return shlex.split(base)
    if shutil.which("uv"):
        packages = ["dbt-core>=1.11.2,<2.0", adapter.package]
        if adapter.name == "motherduck":
            packages.append("duckdb==1.5.3")
        command = ["uv", "run"]
        for package in packages:
            command.extend(["--with", package])
        command.append("dbt")
        return command
    if shutil.which("dbt"):
        return ["dbt"]
    raise SystemExit("Neither uv nor dbt is available")


def run_adapter(adapter: AdapterConfig, env: dict[str, str], root: Path, package_root: Path, timeout_seconds: int) -> dict[str, Any]:
    ok, missing = available(adapter, env)
    result: dict[str, Any] = {"adapter": adapter.name, "ok": False, "skipped": False, "missing_env": missing, "commands": []}
    if not ok:
        result["skipped"] = True
        return result

    project_dir = root / adapter.name
    write_project(project_dir, package_root, adapter)
    dbt = dbt_command(adapter)
    commands = [
        ("deps", [*dbt, "deps", "--profiles-dir", "."]),
        ("debug", [*dbt, "debug", "--profiles-dir", "."]),
        ("build", [*dbt, "build", "--profiles-dir", "."]),
        ("assert", [*dbt, "run-operation", "semantic_rails_assert_contracts", "--profiles-dir", "."]),
    ]

    result["ok"] = True
    for name, argv in commands:
        print(f"==> [{adapter.name}] {name}", flush=True)
        record = command_record(argv, project_dir, env, timeout_seconds)
        record["name"] = name
        result["commands"].append(record)
        if record["returncode"] != 0:
            result["ok"] = False
            if record.get("stdout_tail"):
                print(record["stdout_tail"], file=sys.stderr)
            if record.get("stderr_tail"):
                print(record["stderr_tail"], file=sys.stderr)
            break

    print(f"==> [{adapter.name}] cleanup", flush=True)
    cleanup = command_record([*dbt, "run-operation", "cleanup_live_probe", "--profiles-dir", "."], project_dir, env, timeout_seconds)
    cleanup["name"] = "cleanup"
    result["commands"].append(cleanup)
    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", default=None, help="Optional shell-style env file with live adapter credentials")
    parser.add_argument("--adapter", action="append", choices=sorted(ADAPTERS), help="Adapter to run; may be repeated. Defaults to all.")
    parser.add_argument("--work-dir", default="target/live_adapter_smoke", help="Generated dbt project root")
    parser.add_argument("--output", "-o", default=None, help="Write JSON report to this path")
    parser.add_argument("--timeout-seconds", type=int, default=300)
    args = parser.parse_args(argv)

    if yaml is None:
        raise SystemExit("PyYAML is required. Install requirements-dev.txt or run with uv.")

    package_root = Path(__file__).resolve().parents[1]
    env = load_environment(args.env_file)
    selected = args.adapter or sorted(ADAPTERS)
    work_dir = (package_root / args.work_dir).resolve()
    work_dir.mkdir(parents=True, exist_ok=True)

    results = [
        run_adapter(ADAPTERS[name], env, work_dir, package_root, args.timeout_seconds)
        for name in selected
    ]
    failed = [result for result in results if not result["ok"] and not result["skipped"]]
    skipped = [result for result in results if result["skipped"]]
    report = {
        "ok": not failed,
        "adapter_count": len(results),
        "passed_count": len(results) - len(failed) - len(skipped),
        "failed_count": len(failed),
        "skipped_count": len(skipped),
        "results": results,
    }
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(
        "Semantic Rails live dbt adapter smoke "
        f"{'passed' if report['ok'] else 'failed'}: "
        f"{report['passed_count']} passed, {report['failed_count']} failed, {report['skipped_count']} skipped."
    )
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
