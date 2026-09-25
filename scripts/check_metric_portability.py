#!/usr/bin/env python3
"""Authoring-only conformance: engine corpus -> native dbt validation binding."""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import yaml
from mf2sr.translate import translate
from semantic_rails.contracts import export_metric_portability, load_contract_fixture

from export_semantic_rails_contract import build_contract, parser


def main() -> None:
    output = Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    corpus = load_contract_fixture("metric_portability.v1.json")
    # mf2sr refuses a nonempty package destination; this lane owns its output folder.
    shutil.rmtree(output.parent / corpus["package_id"], ignore_errors=True)
    source = output.parent / "semantic_manifest.json"
    source.write_text(json.dumps(corpus["framework_input"]))
    imported = translate(
        source,
        output.parent,
        package_id=corpus["package_id"],
        namespace=corpus["namespace"],
    )
    portable = export_metric_portability(
        imported.package_dir, import_provenance=imported.provenance
    )
    assert [row["id"] for row in portable["metrics"]] == corpus["expected_metric_ids"]
    args = parser().parse_args(
        [
            str(imported.package_dir),
            "--dbt-package",
            "semantic_rails_contracts_integration_tests",
            "--dbt-version",
            "1",
            "--access",
            "public",
            "--contract-enforced",
            "true",
        ]
    )
    bound = build_contract(args)
    assert (
        bound["semantic"]["packages"][0]["semantic_hash"]
        == portable["package"]["semantic_hash"]
    )
    output.write_text(yaml.safe_dump(bound, sort_keys=False))
    output.with_suffix(".json").write_text(json.dumps({"contract": bound}))


if __name__ == "__main__":
    main()
