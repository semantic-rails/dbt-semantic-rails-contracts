#!/usr/bin/env python3
"""Authoring-only conformance: engine corpus -> native dbt validation binding."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml
from semantic_rails.contracts import export_metric_portability, load_contract_fixture

from export_semantic_rails_contract import build_contract, parser

# Natively authored package for the engine corpus. The engine owns the corpus
# identity and expected metric IDs; this package must reproduce them.
PORTABLE_PACKAGE = Path(__file__).resolve().parents[1] / "integration_tests" / "portable_customers"


def main() -> None:
    output = Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    corpus = load_contract_fixture("metric_portability.v1.json")
    portable = export_metric_portability(PORTABLE_PACKAGE)
    identity = (portable["package"]["id"], portable["package"]["namespace"])
    if identity != (corpus["package_id"], corpus["namespace"]):
        raise SystemExit(f"Expected corpus package {(corpus['package_id'], corpus['namespace'])}, got {identity}.")
    metric_ids = [row["id"] for row in portable["metrics"]]
    if metric_ids != corpus["expected_metric_ids"]:
        raise SystemExit(f"Expected corpus metrics {corpus['expected_metric_ids']}, got {metric_ids}.")
    args = parser().parse_args(
        [
            str(PORTABLE_PACKAGE),
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
    bound_hash = bound["semantic"]["packages"][0]["semantic_hash"]
    if bound_hash != portable["package"]["semantic_hash"]:
        raise SystemExit(
            f"Bound semantic_hash {bound_hash} differs from the engine's "
            f"{portable['package']['semantic_hash']}."
        )
    output.write_text(yaml.safe_dump(bound, sort_keys=False))
    output.with_suffix(".json").write_text(json.dumps({"contract": bound}))


if __name__ == "__main__":
    main()
