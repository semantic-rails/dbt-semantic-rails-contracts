#!/usr/bin/env python3
"""Verify adapter, contract, tag, and approved engine identities."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import urlparse

import yaml

ROOT = Path(__file__).resolve().parent.parent
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def _normalized_requirement(value: str) -> str:
    return value.lower().replace("_", "-").replace(" ", "")


def _requirement_present(rows: list[str], name: str, specifier: str) -> bool:
    expected = _normalized_requirement(name + specifier)
    return any(_normalized_requirement(row) == expected for row in rows)


def _resolve_remote_tag(repository: str, tag: str) -> str:
    result = subprocess.run(
        [
            "git",
            "ls-remote",
            repository,
            f"refs/tags/{tag}",
            f"refs/tags/{tag}^{{}}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    direct: str | None = None
    peeled: str | None = None
    for line in result.stdout.splitlines():
        sha, ref = line.split(maxsplit=1)
        if ref.endswith("^{}"):
            peeled = sha
        elif ref == f"refs/tags/{tag}":
            direct = sha
    resolved = peeled or direct
    if resolved is None:
        raise SystemExit(f"Engine tag {tag} was not found in {repository}.")
    return resolved


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default=None)
    parser.add_argument("--verify-engine-tag", action="store_true")
    parser.add_argument("--allow-placeholder-engine-sha", action="store_true")
    parser.add_argument("--github-env", type=Path, default=None)
    args = parser.parse_args(argv)

    manifest = json.loads((ROOT / "compatibility.json").read_text(encoding="utf-8"))
    project = yaml.safe_load((ROOT / "dbt_project.yml").read_text(encoding="utf-8"))
    package = manifest["package"]
    engine = manifest["engine"]
    dbt = manifest["dbt"]
    adapter = manifest["dbt_adapter"]

    version = str(project["version"])
    if (
        package.get("name") != "dbt-semantic-rails-contracts"
        or package.get("dbt_project_name") != project["name"]
        or package.get("version") != version
        or package.get("runtime_python") != ">=3.10"
        or package.get("export_python") != ">=3.11"
    ):
        raise SystemExit("compatibility.json package identity must match dbt_project.yml.")
    if args.tag is not None and args.tag != f"v{version}":
        raise SystemExit(f"Release tag {args.tag} does not match package version v{version}.")

    requirements = [
        row.strip()
        for row in (ROOT / "requirements-dev.txt").read_text(encoding="utf-8").splitlines()
        if row.strip() and not row.lstrip().startswith("#")
    ]
    expected_requirements = (
        ("semantic-rails", str(engine["specifier"])),
        ("dbt-core", str(dbt["specifier"])),
        (str(adapter["name"]), str(adapter["specifier"])),
    )
    for name, specifier in expected_requirements:
        if not _requirement_present(requirements, name, specifier):
            raise SystemExit(
                f"requirements-dev.txt must contain the compatibility requirement {name}{specifier}."
            )

    expected_prefix = "https://semantic-rails.com/schemas/"
    local_schema_names = set(manifest["adapter_owned_schema_files"]) | {
        "validation_report.v1.json"
    }
    baseline_schema_names = {
        path.name for path in (ROOT / "compatibility" / "baseline" / "v1").glob("*.json")
    }
    if baseline_schema_names != set(manifest["adapter_owned_schema_files"]):
        raise SystemExit(
            "The immutable v1 baseline must contain every adapter-owned schema exactly once."
        )
    for contract_name, contract in manifest["contracts"].items():
        schema_id = str(contract["schema_id"])
        if not schema_id.startswith(expected_prefix):
            raise SystemExit(f"{contract_name} schema_id must use {expected_prefix}.")
        schema_name = Path(urlparse(schema_id).path).name
        if schema_name not in local_schema_names:
            continue
        schema_path = ROOT / "schemas" / schema_name
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        if schema.get("$id") != schema_id:
            raise SystemExit(f"{schema_path.name} $id does not match compatibility.json.")

    candidate_sha = engine.get("engine_candidate_sha")
    candidate_ready = isinstance(candidate_sha, str) and SHA_RE.fullmatch(candidate_sha) is not None
    if not candidate_ready and not args.allow_placeholder_engine_sha:
        raise SystemExit(
            "compatibility.json engine.engine_candidate_sha is still a placeholder; "
            "fill it with the exact public engine commit before release."
        )

    resolved_engine_sha: str | None = None
    if args.verify_engine_tag:
        if not candidate_ready:
            raise SystemExit("Cannot verify the engine tag until engine_candidate_sha is filled.")
        resolved_engine_sha = _resolve_remote_tag(str(engine["repository"]), str(engine["tag"]))
        if resolved_engine_sha != candidate_sha:
            raise SystemExit(
                f"Engine tag {engine['tag']} resolves to {resolved_engine_sha}, "
                f"not approved candidate {candidate_sha}."
            )

    if args.github_env is not None:
        rows = {
            "ADAPTER_VERSION": version,
            "ENGINE_VERSION": str(engine["version"]),
            "ENGINE_TAG": str(engine["tag"]),
            "ENGINE_CANDIDATE_SHA": str(candidate_sha or ""),
            "DBT_RELEASE_TEST_VERSION": str(dbt["release_test_version"]),
            "DBT_ADAPTER_RELEASE_TEST_VERSION": str(adapter["release_test_version"]),
        }
        with args.github_env.open("a", encoding="utf-8") as handle:
            for key, value in rows.items():
                handle.write(f"{key}={value}\n")

    print(
        json.dumps(
            {
                "ok": True,
                "package": package,
                "engine": {
                    "version": engine["version"],
                    "tag": engine["tag"],
                    "engine_candidate_sha": candidate_sha,
                    "candidate_ready": candidate_ready,
                    "resolved_tag_sha": resolved_engine_sha,
                },
                "dbt": dbt,
                "dbt_adapter": adapter,
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
