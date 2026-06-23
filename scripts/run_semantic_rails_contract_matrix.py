#!/usr/bin/env python3
"""Run Semantic Rails dbt contract checks across multiple dbt projects."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

try:
    import yaml
except ModuleNotFoundError:
    yaml = None  # type: ignore[assignment]


TAIL_CHARS = 12000


def load_yaml(path: Path) -> dict[str, Any]:
    if yaml is None:
        raise SystemExit("PyYAML is required. Install requirements-dev.txt or run with uv.")
    if not path.exists():
        raise SystemExit(f"{path} does not exist")
    with path.open("r", encoding="utf-8") as handle:
        payload = yaml.safe_load(handle) or {}
    if not isinstance(payload, dict):
        raise SystemExit(f"{path} must contain a YAML mapping")
    return payload


def resolve_from(base: Path, value: str | None) -> Path | None:
    if not value:
        return None
    path = Path(value).expanduser()
    if path.is_absolute():
        return path
    return (base / path).resolve()


def tail(value: str) -> str:
    if len(value) <= TAIL_CHARS:
        return value
    return value[-TAIL_CHARS:]


def contract_payload(project_dir: Path, project: dict[str, Any]) -> dict[str, Any] | None:
    if project.get("contract_file") and project.get("contract"):
        raise SystemExit(f"{project_name(project)} cannot define both contract_file and contract")
    if project.get("contract_file"):
        payload = load_yaml(resolve_from(project_dir, str(project["contract_file"])) or project_dir)
    elif project.get("contract"):
        payload = project["contract"]
        if not isinstance(payload, dict):
            raise SystemExit(f"{project_name(project)} contract must be a mapping")
    else:
        return None
    if "semantic_rails_contracts" in payload:
        nested = payload["semantic_rails_contracts"]
        if not isinstance(nested, dict):
            raise SystemExit(f"{project_name(project)} semantic_rails_contracts must be a mapping")
        return nested
    return payload


def project_name(project: dict[str, Any]) -> str:
    return str(project.get("name") or project.get("project_dir") or "<unnamed>")


def bool_value(project: dict[str, Any], name: str, default: bool) -> bool:
    value = project.get(name, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes", "on"}
    return bool(value)


def command_record(
    *,
    name: str,
    argv: list[str],
    cwd: Path,
    env: dict[str, str],
    timeout_seconds: int | None,
) -> dict[str, Any]:
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
            "name": name,
            "argv": argv,
            "returncode": completed.returncode,
            "duration_seconds": round(time.monotonic() - started, 3),
            "stdout_tail": tail(completed.stdout),
            "stderr_tail": tail(completed.stderr),
        }
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
        return {
            "name": name,
            "argv": argv,
            "returncode": 124,
            "duration_seconds": round(time.monotonic() - started, 3),
            "stdout_tail": tail(stdout),
            "stderr_tail": tail((stderr + f"\nTimed out after {timeout_seconds} seconds.").strip()),
        }


def operation_args(project: dict[str, Any], contract: dict[str, Any] | None) -> list[str]:
    payload: dict[str, Any] = {}
    if contract is not None:
        payload["contract"] = contract
    if project.get("var_name") and project["var_name"] != "semantic_rails_contracts":
        payload["var_name"] = project["var_name"]
    if bool_value(project, "warn_only", False):
        payload["warn_only"] = True
    if not payload:
        return []
    return ["--args", json.dumps(payload, sort_keys=True)]


def dbt_flags(project: dict[str, Any], profiles_dir: Path | None, include_target: bool = True) -> list[str]:
    flags: list[str] = []
    if profiles_dir is not None:
        flags.extend(["--profiles-dir", str(profiles_dir)])
    if include_target and project.get("target"):
        flags.extend(["--target", str(project["target"])])
    if include_target and project.get("profile"):
        flags.extend(["--profile", str(project["profile"])])
    return flags


def run_project(
    *,
    dbt_command: list[str],
    config_dir: Path,
    defaults: dict[str, Any],
    raw_project: dict[str, Any],
    fail_fast: bool,
) -> dict[str, Any]:
    project = {**defaults, **raw_project}
    name = project_name(project)
    if not project.get("project_dir"):
        raise SystemExit(f"{name} is missing project_dir")

    project_dir = resolve_from(config_dir, str(project["project_dir"]))
    if project_dir is None or not (project_dir / "dbt_project.yml").exists():
        raise SystemExit(f"{name} project_dir must point at a dbt project")

    profiles_dir = resolve_from(project_dir, str(project.get("profiles_dir"))) if project.get("profiles_dir") else None
    contract = contract_payload(project_dir, project)
    env = os.environ.copy()
    for key, value in dict(project.get("env") or {}).items():
        env[str(key)] = str(value)

    timeout_seconds = project.get("timeout_seconds")
    timeout = int(timeout_seconds) if timeout_seconds else None
    macro_name = str(project.get("macro") or "semantic_rails_assert_contracts")
    commands: list[tuple[str, list[str]]] = []

    if bool_value(project, "run_deps", True):
        commands.append(("deps", [*dbt_command, "deps", *dbt_flags(project, profiles_dir, include_target=False)]))
    if bool_value(project, "run_parse", True):
        commands.append(("parse", [*dbt_command, "parse", *dbt_flags(project, profiles_dir)]))
    if bool_value(project, "build", False):
        build_args = [*dbt_command, "build", *dbt_flags(project, profiles_dir)]
        if project.get("build_select"):
            build_args.extend(["--select", str(project["build_select"])])
        commands.append(("build", build_args))

    assert_args = [
        *dbt_command,
        "run-operation",
        macro_name,
        *dbt_flags(project, profiles_dir),
        *operation_args(project, contract),
    ]
    commands.append(("assert", assert_args))

    result = {
        "name": name,
        "project_dir": str(project_dir),
        "profiles_dir": str(profiles_dir) if profiles_dir else None,
        "target": project.get("target"),
        "profile": project.get("profile"),
        "ok": True,
        "commands": [],
    }

    for command_name, argv in commands:
        print(f"==> [{name}] {command_name}", flush=True)
        record = command_record(name=command_name, argv=argv, cwd=project_dir, env=env, timeout_seconds=timeout)
        result["commands"].append(record)
        if record["returncode"] != 0:
            result["ok"] = False
            if record.get("stdout_tail"):
                print(record["stdout_tail"], file=sys.stderr)
            if record.get("stderr_tail"):
                print(record["stderr_tail"], file=sys.stderr)
            if fail_fast:
                break
    return result


def run_matrix(args: argparse.Namespace) -> dict[str, Any]:
    config_path = Path(args.config).expanduser().resolve()
    config = load_yaml(config_path)
    defaults = dict(config.get("defaults") or {})
    projects = config.get("projects")
    if not isinstance(projects, list) or not projects:
        raise SystemExit("matrix config must define a non-empty projects list")

    dbt_command = shlex.split(args.dbt_command)
    if not dbt_command:
        raise SystemExit("--dbt-command cannot be empty")

    results = []
    for project in projects:
        if not isinstance(project, dict):
            raise SystemExit("each matrix projects entry must be a mapping")
        result = run_project(
            dbt_command=dbt_command,
            config_dir=config_path.parent,
            defaults=defaults,
            raw_project=project,
            fail_fast=args.fail_fast,
        )
        results.append(result)
        if args.fail_fast and not result["ok"]:
            break

    failed = [project for project in results if not project["ok"]]
    return {
        "ok": not failed,
        "project_count": len(results),
        "passed_count": len(results) - len(failed),
        "failed_count": len(failed),
        "projects": results,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", help="YAML matrix config with projects to check")
    parser.add_argument("--dbt-command", default=os.environ.get("DBT_COMMAND", "dbt"))
    parser.add_argument("--output", "-o", help="Write aggregate JSON report to this path")
    parser.add_argument("--fail-fast", action="store_true", help="Stop commands for a project after its first failure")
    args = parser.parse_args(argv)

    if yaml is None:
        raise SystemExit("PyYAML is required. Install requirements-dev.txt or run with uv.")
    report = run_matrix(args)
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    status = "passed" if report["ok"] else "failed"
    print(
        f"Semantic Rails dbt contract matrix {status}: "
        f"{report['passed_count']}/{report['project_count']} project(s) passed."
    )
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
