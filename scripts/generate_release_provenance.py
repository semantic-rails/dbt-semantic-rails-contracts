#!/usr/bin/env python3
"""Generate checksums and machine-readable provenance for verified release bytes."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
from importlib.metadata import version
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def artifact(path: Path) -> dict[str, Any]:
    return {
        "filename": path.name,
        "sha256": sha256(path),
        "size": path.stat().st_size,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-archive", type=Path, required=True)
    parser.add_argument("--engine-wheel-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args(argv)

    manifest_path = ROOT / "compatibility.json"
    compatibility = json.loads(manifest_path.read_text(encoding="utf-8"))
    adapter_version = str(compatibility["package"]["version"])
    engine_version = str(compatibility["engine"]["version"])
    dbt_version = str(compatibility["dbt"]["release_test_version"])
    dbt_adapter_name = str(compatibility["dbt_adapter"]["name"])
    dbt_adapter_version = str(compatibility["dbt_adapter"]["release_test_version"])

    if version("semantic-rails") != engine_version:
        raise SystemExit("Installed engine does not match compatibility.json.")
    if version("dbt-core") != dbt_version:
        raise SystemExit("Installed dbt-core does not match compatibility.json release_test_version.")
    if version(dbt_adapter_name) != dbt_adapter_version:
        raise SystemExit(
            f"Installed {dbt_adapter_name} does not match compatibility.json release_test_version."
        )
    if not args.source_archive.is_file():
        raise SystemExit(f"Release source archive does not exist: {args.source_archive}")

    engine_wheels = sorted(args.engine_wheel_dir.glob("semantic_rails-*.whl"))
    if len(engine_wheels) != 1:
        raise SystemExit("Expected one exact semantic-rails engine wheel.")

    schemas = []
    for path in sorted((ROOT / "schemas").glob("*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        schemas.append({**artifact(path), "schema_id": payload.get("$id")})

    source_artifact = artifact(args.source_archive)
    provenance = {
        "provenance_format_version": 1,
        "release": {
            "package": compatibility["package"]["name"],
            "version": adapter_version,
            "tag": args.tag,
            "source_commit": args.git_sha,
        },
        "engine_candidate": {
            "distribution": compatibility["engine"]["name"],
            "version": engine_version,
            "tag": compatibility["engine"]["tag"],
            "source_commit": compatibility["engine"]["engine_candidate_sha"],
            "wheel": artifact(engine_wheels[0]),
        },
        "resolved_test_environment": {
            "python": platform.python_version(),
            "dbt-core": version("dbt-core"),
            dbt_adapter_name: version(dbt_adapter_name),
            "semantic-rails": version("semantic-rails"),
        },
        "artifacts": [source_artifact],
        "schemas": schemas,
        "compatibility_manifest": {
            **artifact(manifest_path),
            "manifest_version": compatibility["manifest_version"],
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (args.output.parent / "SHA256SUMS").write_text(
        f"{source_artifact['sha256']}  {source_artifact['filename']}\n",
        encoding="utf-8",
    )
    print(json.dumps(provenance, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
