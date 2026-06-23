#!/usr/bin/env python3
"""Export a dbt vars contract from a Semantic Rails package directory."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ModuleNotFoundError:
    yaml = None  # type: ignore[assignment]

try:
    from sqlglot import exp, parse_one
except ModuleNotFoundError:  # pragma: no cover - optional helper dependency.
    exp = None  # type: ignore[assignment]
    parse_one = None  # type: ignore[assignment]

SQL_KEYWORDS = {
    "and",
    "as",
    "case",
    "cast",
    "coalesce",
    "date",
    "distinct",
    "else",
    "end",
    "false",
    "from",
    "interval",
    "is",
    "not",
    "null",
    "or",
    "then",
    "true",
    "when",
}
GENERATED_CONTRACT_NAMES = {
    "semantic_rails_contract.yml",
    "semantic_rails_contract.yaml",
    "semantic_rails_contracts.yml",
    "semantic_rails_contracts.yaml",
}
IGNORED_PACKAGE_DIRS = {".git", ".sqlmesh", ".venv", "__pycache__", "dbt_packages", "logs", "target"}

EXPRESSION_CHILD_KEYS = {
    "else",
    "expression",
    "expr",
    "input",
    "left",
    "right",
    "then",
    "when",
    "whens",
}


def load_yaml(path: Path) -> dict[str, Any]:
    if yaml is None:
        raise SystemExit("PyYAML is required. Install requirements-dev.txt or run with uv.")
    with path.open("r", encoding="utf-8") as handle:
        return dict(yaml.safe_load(handle) or {})


def load_package_documents(root: Path) -> list[dict[str, Any]]:
    docs: list[dict[str, Any]] = []
    if root.is_file():
        docs.append(load_yaml(root))
        return docs
    for path in iter_package_yaml_files(root):
        docs.append(load_yaml(path))
    return docs


def package_hash(root: Path) -> str:
    digest = hashlib.sha256()
    if root.is_file():
        digest.update(root.read_bytes())
        return "sha256:" + digest.hexdigest()
    for path in iter_package_yaml_files(root):
        digest.update(str(path.relative_to(root)).encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return "sha256:" + digest.hexdigest()


def iter_package_yaml_files(root: Path) -> list[Path]:
    paths = [*root.rglob("*.yml"), *root.rglob("*.yaml")]
    out: list[Path] = []
    for path in sorted(set(paths)):
        relative_parts = path.relative_to(root).parts
        if any(part.startswith(".") or part in IGNORED_PACKAGE_DIRS for part in relative_parts):
            continue
        if path.name in GENERATED_CONTRACT_NAMES or path.name.startswith("semantic_rails_contract_"):
            continue
        out.append(path)
    return out


def collect_package_meta(docs: list[dict[str, Any]]) -> dict[str, Any]:
    for doc in docs:
        if isinstance(doc.get("package"), dict):
            package = dict(doc["package"])
            return {
                "package_id": package.get("id") or package.get("name") or "",
                "namespace": package.get("namespace") or package.get("id") or "",
                "schema_version": doc.get("schema_version", 1),
            }
    return {"package_id": "", "namespace": "", "schema_version": 1}


def collect_entities(docs: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    entities: dict[str, dict[str, Any]] = {}
    for doc in docs:
        graph = doc.get("graph") or {}
        for name, payload in dict(graph.get("entities") or {}).items():
            entities[str(name)] = dict(payload or {})
    return entities


def iter_model_payloads(docs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    models: list[dict[str, Any]] = []
    for doc in docs:
        if isinstance(doc.get("model"), dict):
            models.append(dict(doc["model"]))
        for name, payload in dict(doc.get("models") or {}).items():
            row = dict(payload or {})
            row.setdefault("id", str(name))
            models.append(row)
    return models


def as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value]
    return [str(value)]


def add_column(columns: dict[str, set[str]], name: str | None, required_by: str) -> None:
    if not name:
        return
    clean = str(name).strip()
    if not clean or clean == "*":
        return
    if "." in clean:
        clean = clean.split(".")[-1]
    columns.setdefault(clean, set()).add(required_by)


def columns_from_expr(expr: Any) -> set[str]:
    found: set[str] = set()
    if expr is None:
        return found
    if isinstance(expr, str):
        return columns_from_sql_string(expr)
    if isinstance(expr, list):
        for item in expr:
            found.update(columns_from_expr(item))
        return found
    if isinstance(expr, dict):
        if expr.get("kind") == "column" and expr.get("column"):
            found.add(str(expr["column"]))
        for key, value in expr.items():
            if key in EXPRESSION_CHILD_KEYS:
                found.update(columns_from_expr(value))
        return found
    return found


def columns_from_sql_string(expr: str) -> set[str]:
    parsed_columns = columns_from_sqlglot(expr)
    if parsed_columns:
        return parsed_columns
    return columns_from_tokens(expr)


def columns_from_sqlglot(expr: str) -> set[str]:
    if parse_one is None or exp is None:
        return set()
    try:
        parsed = parse_one(expr, error_level="ignore")
    except Exception:
        return set()
    if parsed is None:
        return set()
    return {column.name for column in parsed.find_all(exp.Column) if column.name and column.name != "*"}


def columns_from_tokens(expr: str) -> set[str]:
    found: set[str] = set()
    without_literals = re.sub(r"'([^']|'')*'", " ", expr)
    for match in re.finditer(r"[A-Za-z_][A-Za-z0-9_\.]*", without_literals):
        token = match.group(0)
        bare = token.split(".")[-1].lower()
        remainder = without_literals[match.end() :].lstrip()
        if bare in SQL_KEYWORDS or bare.isdigit() or remainder.startswith("("):
            continue
        found.add(token.split(".")[-1])
    return found


def model_required_columns(model: dict[str, Any], entities: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    columns: dict[str, set[str]] = {}
    model_id = str(model.get("id") or model.get("name") or "")

    for entity_name, payload in dict(model.get("entities") or {}).items():
        entity_payload = dict(payload or {})
        for name in columns_from_expr(entity_payload.get("expr")):
            add_column(columns, name, f"entity.{entity_name}")
        if not entity_payload.get("expr"):
            entity = entities.get(str(entity_name), {})
            for key in as_list(entity.get("key")):
                add_column(columns, key, f"entity.{entity_name}")

    for time_name, payload in dict(model.get("times") or {}).items():
        row = dict(payload or {})
        add_column(columns, row.get("column") or time_name, f"time.{time_name}")

    for dimension_name, payload in dict(model.get("dimensions") or {}).items():
        row = dict(payload or {})
        add_column(columns, row.get("column") or dimension_name, f"dimension.{dimension_name}")
        for name in columns_from_expr(row.get("expr")):
            add_column(columns, name, f"dimension.{dimension_name}")

    for measure_name, payload in dict(model.get("measures") or {}).items():
        row = dict(payload or {})
        add_column(columns, row.get("entity_key"), f"measure.{measure_name}")
        for name in columns_from_expr(row.get("expr")):
            add_column(columns, name, f"measure.{measure_name}")

    return [
        {"name": name, "required_by": sorted(required_by)}
        for name, required_by in sorted(columns.items())
        if name and name != model_id
    ]


def parse_model_map(values: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for value in values:
        left, sep, right = value.partition("=")
        if not sep or not left.strip() or not right.strip():
            raise SystemExit(f"Invalid --model-map value {value!r}; expected semantic_model=dbt_model")
        out[left.strip()] = right.strip()
    return out


def build_contract(args: argparse.Namespace) -> dict[str, Any]:
    if args.dbt_resource_type != "model" and any(
        value is not None for value in (args.dbt_version, args.latest_version, args.access)
    ):
        raise SystemExit("--dbt-version, --latest-version, and --access only apply to --dbt-resource-type model")
    if args.dbt_resource_type != "model" and args.require_model_version:
        raise SystemExit("--require-model-version only applies to --dbt-resource-type model")

    root = Path(args.semantic_package).resolve()
    docs = load_package_documents(root)
    meta = collect_package_meta(docs)
    entities = collect_entities(docs)
    model_map = parse_model_map(args.model_map or [])
    include = set(args.include_model or [])

    models: list[dict[str, Any]] = []
    for model in iter_model_payloads(docs):
        model_id = str(model.get("id") or model.get("name") or "")
        if include and model_id not in include:
            continue
        dbt_model = model_map.get(model_id, f"{args.dbt_model_prefix}{model_id}{args.dbt_model_suffix}")
        row = {
            "semantic_model_id": model_id,
            "semantic_relation": model.get("relation"),
            "dbt_resource_type": args.dbt_resource_type,
            "dbt_model": dbt_model,
            "dbt_package": args.dbt_package,
            "allow_extra_columns": args.allow_extra_columns,
            "columns": model_required_columns(model, entities),
        }
        if args.dbt_resource_type == "source":
            if not args.dbt_source_name:
                raise SystemExit("--dbt-source-name is required when --dbt-resource-type source is used")
            row["dbt_source_name"] = args.dbt_source_name
            row["dbt_source_table"] = dbt_model
        if args.dbt_resource_type == "model":
            row["dbt_version"] = args.dbt_version
            row["latest_version"] = args.latest_version if args.latest_version is not None else args.dbt_version
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
        models.append(row)

    return {
        "semantic_rails_contracts": {
            "packages": [
                {
                    **meta,
                    "contract_version": 1,
                    "semantic_hash": package_hash(root),
                    "accepted_semantic_hashes": [package_hash(root)],
                    "policy": {
                        "severity": args.severity,
                        "require_model_contract": args.contract_enforced if args.dbt_resource_type == "model" else False,
                        "require_model_version": args.require_model_version if args.dbt_resource_type == "model" else False,
                        "type_check": args.type_check,
                        "allow_extra_columns": args.allow_extra_columns,
                    },
                    "models": models,
                }
            ]
        }
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("semantic_package", help="Semantic Rails package directory or single-file package")
    parser.add_argument("--output", "-o", help="Write YAML to this path instead of stdout")
    parser.add_argument("--dbt-package", default="", help="Expected dbt package/project name; defaults to root project when omitted")
    parser.add_argument("--dbt-resource-type", default="model", choices=["model", "source", "seed", "snapshot"], help="dbt graph resource type to map Semantic Rails models to")
    parser.add_argument("--dbt-source-name", default=None, help="dbt source name for --dbt-resource-type source")
    parser.add_argument("--dbt-model-prefix", default="", help="Prefix to apply when mapping Semantic Rails model ids to dbt model names")
    parser.add_argument("--dbt-model-suffix", default="", help="Suffix to apply when mapping Semantic Rails model ids to dbt model names")
    parser.add_argument("--model-map", action="append", default=[], help="Explicit mapping semantic_model=dbt_model; may be repeated")
    parser.add_argument("--include-model", action="append", default=[], help="Only export this Semantic Rails model id; may be repeated")
    parser.add_argument("--dbt-version", type=int, default=None, help="Expected dbt model version")
    parser.add_argument("--latest-version", type=int, default=None, help="Expected dbt latest_version; defaults to --dbt-version")
    parser.add_argument("--access", default=None, choices=["private", "protected", "public"])
    parser.add_argument("--dbt-alias", default=None, help="Expected dbt graph alias for every exported resource")
    parser.add_argument("--dbt-schema", default=None, help="Expected dbt graph schema for every exported resource")
    parser.add_argument("--dbt-database", default=None, help="Expected dbt graph database for every exported resource")
    parser.add_argument("--dbt-identifier", default=None, help="Expected dbt graph identifier for every exported resource")
    parser.add_argument("--dbt-relation-name", default=None, help="Expected dbt graph relation_name for every exported resource")
    parser.add_argument("--severity", default="error", choices=["error", "warn"])
    parser.add_argument("--type-check", default="ignore", choices=["ignore", "compatible", "exact"])
    parser.add_argument("--contract-enforced", default=True, type=lambda value: str(value).lower() in {"1", "true", "yes"})
    parser.add_argument("--allow-extra-columns", default=True, type=lambda value: str(value).lower() in {"1", "true", "yes"})
    parser.add_argument("--require-model-version", default=False, type=lambda value: str(value).lower() in {"1", "true", "yes"})
    args = parser.parse_args(argv)

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
