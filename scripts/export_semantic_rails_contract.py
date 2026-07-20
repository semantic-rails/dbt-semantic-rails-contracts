#!/usr/bin/env python3
"""Compose a dbt binding with an engine-produced Semantic Rails contract."""

from __future__ import annotations

import argparse
import copy
import sys
from pathlib import Path
from typing import Any, Callable

try:
    import yaml
except ModuleNotFoundError:
    yaml = None  # type: ignore[assignment]


EngineExporter = Callable[[str | Path], dict[str, Any]]


def engine_exporter() -> EngineExporter:
    """Return the one supported engine producer API.

    Keeping this import at one boundary makes an API rename explicit while the
    dbt package remains Python-free at dbt parse and execution time.
    """

    try:
        from semantic_rails.contracts import export_semantic_contract
    except (ImportError, ModuleNotFoundError) as exc:
        raise SystemExit(
            "Semantic Rails with the public contract producer API is required for export. "
            "Install semantic-rails>=0.2,<0.3; dbt runtime macros do not import it."
        ) from exc
    return export_semantic_contract


def load_semantic_contract(path: Path, exporter: EngineExporter | None = None) -> dict[str, Any]:
    producer = exporter or engine_exporter()
    payload = producer(path)
    if not isinstance(payload, dict):
        raise SystemExit("semantic_rails.contracts.export_semantic_contract must return a mapping")
    if payload.get("contract_format_version") != 1:
        raise SystemExit("Semantic Rails producer returned an unsupported contract_format_version; expected 1")
    semantic = payload.get("semantic")
    if not isinstance(semantic, dict):
        raise SystemExit("Semantic Rails producer returned no semantic mapping")
    packages = semantic.get("packages")
    if not isinstance(packages, list) or not packages:
        raise SystemExit("Semantic Rails producer returned no semantic packages")
    return copy.deepcopy(payload)


def parse_model_map(values: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for value in values:
        left, sep, right = value.partition("=")
        if not sep or not left.strip() or not right.strip():
            raise SystemExit(f"Invalid --model-map value {value!r}; expected semantic_model=dbt_model")
        out[left.strip()] = right.strip()
    return out


def selected_semantic_contract(payload: dict[str, Any], include: set[str]) -> dict[str, Any]:
    if not include:
        return payload
    found: set[str] = set()
    packages: list[dict[str, Any]] = []
    for raw_package in payload["semantic"]["packages"]:
        package = dict(raw_package)
        resources: list[dict[str, Any]] = []
        for raw_resource in package.get("resources", []):
            resource_id = str(raw_resource.get("semantic_model_id") or "")
            if resource_id in include:
                resources.append(dict(raw_resource))
                found.add(resource_id)
        if resources:
            package["resources"] = resources
            packages.append(package)
    missing = sorted(include - found)
    if missing:
        raise SystemExit("Unknown --include-model value(s): " + ", ".join(missing))
    payload["semantic"]["packages"] = packages
    return payload


def validate_args(args: argparse.Namespace) -> None:
    if args.dbt_resource_type != "model" and any(
        value is not None for value in (args.dbt_version, args.latest_version, args.access)
    ):
        raise SystemExit("--dbt-version, --latest-version, and --access only apply to --dbt-resource-type model")
    if args.dbt_resource_type != "model" and args.require_model_version:
        raise SystemExit("--require-model-version only applies to --dbt-resource-type model")
    if args.dbt_resource_type == "source" and not args.dbt_source_name:
        raise SystemExit("--dbt-source-name is required when --dbt-resource-type source is used")


def dbt_binding_resource(
    semantic_resource: dict[str, Any],
    args: argparse.Namespace,
    model_map: dict[str, str],
) -> dict[str, Any]:
    model_id = str(semantic_resource.get("semantic_model_id") or "")
    if not model_id:
        raise SystemExit("Engine-produced semantic resources must include semantic_model_id")
    dbt_model = model_map.get(model_id, f"{args.dbt_model_prefix}{model_id}{args.dbt_model_suffix}")
    row: dict[str, Any] = {
        "semantic_model_id": model_id,
        "dbt_resource_type": args.dbt_resource_type,
        "dbt_model": dbt_model,
    }
    if args.dbt_package:
        row["dbt_package"] = args.dbt_package
    if args.dbt_resource_type == "source":
        row["dbt_source_name"] = args.dbt_source_name
        row["dbt_source_table"] = dbt_model
    elif args.dbt_resource_type == "model":
        if args.dbt_version is not None:
            row["dbt_version"] = args.dbt_version
            row["latest_version"] = (
                args.latest_version if args.latest_version is not None else args.dbt_version
            )
        elif args.latest_version is not None:
            row["latest_version"] = args.latest_version
        if args.access is not None:
            row["access"] = args.access
        row["contract_enforced"] = args.contract_enforced

    for output_key, arg_value in {
        "dbt_alias": args.dbt_alias,
        "dbt_schema": args.dbt_schema,
        "dbt_database": args.dbt_database,
        "dbt_identifier": args.dbt_identifier,
        "dbt_relation_name": args.dbt_relation_name,
    }.items():
        if arg_value is not None:
            row[output_key] = arg_value
    return row


def build_contract(
    args: argparse.Namespace,
    *,
    exporter: EngineExporter | None = None,
) -> dict[str, Any]:
    validate_args(args)
    semantic_path = Path(args.semantic_package).expanduser().resolve()
    payload = load_semantic_contract(semantic_path, exporter=exporter)
    payload = selected_semantic_contract(payload, set(args.include_model or []))
    model_map = parse_model_map(args.model_map or [])

    binding_packages: list[dict[str, Any]] = []
    for semantic_package in payload["semantic"]["packages"]:
        package_id = semantic_package.get("package_id")
        if not isinstance(package_id, str) or not package_id:
            raise SystemExit("Engine-produced semantic packages must include package_id")
        resources = [
            dbt_binding_resource(dict(resource), args, model_map)
            for resource in semantic_package.get("resources", [])
        ]
        if not resources:
            raise SystemExit(f"Engine-produced semantic package {package_id} has no selected resources")
        binding_packages.append(
            {
                "package_id": package_id,
                "policy": {
                    "severity": args.severity,
                    "require_model_contract": (
                        args.contract_enforced if args.dbt_resource_type == "model" else False
                    ),
                    "require_model_version": (
                        args.require_model_version if args.dbt_resource_type == "model" else False
                    ),
                    "type_check": args.type_check,
                    "allow_extra_columns": args.allow_extra_columns,
                },
                "resources": resources,
            }
        )

    payload["binding"] = {
        "kind": "dbt",
        "binding_version": 1,
        "packages": binding_packages,
    }
    return payload


def bool_arg(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("semantic_package", help="Semantic Rails package directory or single-file package")
    value.add_argument("--output", "-o", help="Write YAML to this path instead of stdout")
    value.add_argument(
        "--dbt-package",
        default="",
        help="Expected dbt package/project name; defaults to the active root project when omitted",
    )
    value.add_argument(
        "--dbt-resource-type",
        default="model",
        choices=["model", "source", "seed", "snapshot"],
        help="dbt graph resource type to bind Semantic Rails resources to",
    )
    value.add_argument("--dbt-source-name", default=None)
    value.add_argument("--dbt-model-prefix", default="")
    value.add_argument("--dbt-model-suffix", default="")
    value.add_argument(
        "--model-map",
        action="append",
        default=[],
        help="Explicit mapping semantic_model=dbt_model; may be repeated",
    )
    value.add_argument(
        "--include-model",
        action="append",
        default=[],
        help="Only export this Semantic Rails model id; may be repeated",
    )
    value.add_argument("--dbt-version", type=int, default=None)
    value.add_argument("--latest-version", type=int, default=None)
    value.add_argument("--access", default=None, choices=["private", "protected", "public"])
    value.add_argument("--dbt-alias", default=None)
    value.add_argument("--dbt-schema", default=None)
    value.add_argument("--dbt-database", default=None)
    value.add_argument("--dbt-identifier", default=None)
    value.add_argument("--dbt-relation-name", default=None)
    value.add_argument("--severity", default="error", choices=["error", "warn"])
    value.add_argument("--type-check", default="ignore", choices=["ignore", "compatible", "exact"])
    value.add_argument("--contract-enforced", default=True, type=bool_arg)
    value.add_argument("--allow-extra-columns", default=True, type=bool_arg)
    value.add_argument("--require-model-version", default=False, type=bool_arg)
    return value


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    if yaml is None:
        raise SystemExit("PyYAML is required. Install requirements-dev.txt or run with uv.")
    payload = build_contract(args)
    text = yaml.safe_dump(payload, sort_keys=False)
    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(text, encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
