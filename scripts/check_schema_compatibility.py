#!/usr/bin/env python3
"""Fail when an adapter-owned v1 schema differs from its immutable baseline."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
CURRENT = ROOT / "schemas"
BASELINE = ROOT / "compatibility" / "baseline" / "v1"


def _canonical(path: Path) -> str:
    payload: Any = json.loads(path.read_text(encoding="utf-8"))
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def main() -> int:
    manifest = json.loads((ROOT / "compatibility.json").read_text(encoding="utf-8"))
    names = {str(name) for name in manifest["adapter_owned_schema_files"]}
    baseline_names = {path.name for path in BASELINE.glob("*.json")}
    if baseline_names != names:
        raise SystemExit(
            "Immutable v1 baseline files do not match adapter_owned_schema_files: "
            f"baseline={sorted(baseline_names)} declared={sorted(names)}"
        )

    changed: list[str] = []
    for name in sorted(names):
        current = CURRENT / name
        baseline = BASELINE / name
        if not current.is_file():
            changed.append(f"{name}: current schema missing")
            continue
        if _canonical(current) != _canonical(baseline):
            changed.append(f"{name}: differs from immutable v1 baseline")
    if changed:
        raise SystemExit(
            "Breaking adapter-schema change detected. Publish a new schema major "
            "instead of editing v1:\n - " + "\n - ".join(changed)
        )

    print(
        json.dumps(
            {
                "ok": True,
                "baseline": str(BASELINE),
                "schemas": sorted(names),
                "breaking_changes": [],
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
