#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="${ROOT_DIR}/integration_tests/basic"
EXPORT_FIXTURE="${ROOT_DIR}/integration_tests/semantic_rails_fixture"
EXPORT_OUTPUT="${ROOT_DIR}/integration_tests/basic/target/exported_contract.yml"
SOURCE_EXPORT_OUTPUT="${ROOT_DIR}/integration_tests/basic/target/exported_source_contract.yml"
MATRIX_CONFIG="${ROOT_DIR}/integration_tests/multi_project/matrix.yml"
MATRIX_FAILURE_CONFIG="${ROOT_DIR}/integration_tests/multi_project/matrix_failure.yml"
MATRIX_OUTPUT="${ROOT_DIR}/integration_tests/basic/target/multi_project_report.json"
MATRIX_FAILURE_OUTPUT="${ROOT_DIR}/integration_tests/basic/target/multi_project_failure_report.json"
GOLDEN_CONTRACT="${ROOT_DIR}/integration_tests/contracts/golden_composed_v1.yml"

if [[ -n "${DBT_BIN:-}" ]]; then
  DBT=("${DBT_BIN}")
elif command -v dbt >/dev/null 2>&1; then
  DBT=(dbt)
elif command -v uv >/dev/null 2>&1; then
  DBT=(uv run --with "dbt-core>=1.11.2,<2.0" --with "dbt-duckdb>=1.10,<2.0" dbt)
else
  echo "dbt is not installed. Install requirements-dev.txt or install uv." >&2
  exit 1
fi

if [[ -n "${PYTHON_BIN:-}" ]]; then
  PYTHON=("${PYTHON_BIN}")
elif [[ -n "${SEMANTIC_RAILS_SOURCE:-}" ]] && command -v uv >/dev/null 2>&1; then
  PYTHON=(uv run --with-editable "${SEMANTIC_RAILS_SOURCE}" --with "PyYAML>=6.0" --with "jsonschema>=4.23" python)
elif python -c "from semantic_rails.contracts import export_semantic_contract" >/dev/null 2>&1; then
  PYTHON=(python)
elif command -v uv >/dev/null 2>&1; then
  PYTHON=(uv run --with "semantic-rails>=0.2,<0.3" --with "PyYAML>=6.0" --with "jsonschema>=4.23" python)
else
  PYTHON=(python)
fi

run_success() {
  local name="$1"
  shift
  echo "==> expect success: ${name}"
  "$@"
}

run_failure() {
  local name="$1"
  local expected_code="$2"
  shift 2
  echo "==> expect failure: ${name} (${expected_code})"
  local output
  set +e
  output="$("$@" 2>&1)"
  local status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    echo "Expected failure for ${name}, but command succeeded." >&2
    exit 1
  fi
  if [[ "${output}" != *"${expected_code}"* ]]; then
    echo "Expected ${expected_code} for ${name}, got:" >&2
    echo "${output}" >&2
    exit 1
  fi
}

contract_args() {
  local mode="${1:-valid}"
  "${PYTHON[@]}" - "${GOLDEN_CONTRACT}" "${mode}" <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = yaml.safe_load(handle)
mode = sys.argv[2]
if mode == "format2":
    payload["contract_format_version"] = 2
elif mode == "format_string":
    payload["contract_format_version"] = "1"
elif mode == "binding2":
    payload["binding"]["binding_version"] = 2
elif mode == "binding_string":
    payload["binding"]["binding_version"] = "1"
elif mode == "wrong_kind":
    payload["binding"]["kind"] = "sqlmesh"
elif mode == "package_schema2":
    payload["semantic"]["packages"][0]["package_schema_version"] = 2
elif mode == "malformed_hash":
    payload["semantic"]["packages"][0]["semantic_hash"] = "sha256:not-a-digest"
elif mode == "malformed_columns":
    payload["semantic"]["packages"][0]["resources"][0]["columns"] = "customer_id"
elif mode == "missing_required_by":
    del payload["semantic"]["packages"][0]["resources"][0]["columns"][0]["required_by"]
elif mode == "orphan_binding":
    payload["binding"]["packages"][0]["resources"][0]["semantic_model_id"] = "orphan"
elif mode == "unknown_top_level":
    payload["unexpected"] = True
elif mode == "binding_contains_columns":
    payload["binding"]["packages"][0]["resources"][0]["columns"] = [{"name": "customer_id"}]
elif mode == "binding_boolean_string":
    payload["binding"]["packages"][0]["resources"][0]["contract_enforced"] = "true"
elif mode == "missing_policy":
    del payload["binding"]["packages"][0]["policy"]
elif mode != "valid":
    raise SystemExit(f"unknown contract mutation {mode}")
print(json.dumps({"contract": payload}, sort_keys=True))
PY
}

report_json_from_output() {
  "${PYTHON[@]}" - "$1" <<'PY'
import json
import re
import sys

text = re.sub(r"\x1b\[[0-9;]*m", "", sys.argv[1])
for line in reversed(text.splitlines()):
    start = line.find('{"report_format_version"')
    if start >= 0:
        payload = json.loads(line[start:])
        print(json.dumps(payload, separators=(",", ":")))
        break
else:
    raise SystemExit("ValidationReportV1 JSON line not found in dbt output")
PY
}

cd "${PROJECT_DIR}"

if [[ "${SKIP_EXPORT_TESTS:-false}" != "true" ]]; then
run_success "export Semantic Rails fixture" "${PYTHON[@]}" "${ROOT_DIR}/scripts/export_semantic_rails_contract.py" "${EXPORT_FIXTURE}" --dbt-package semantic_rails_contracts_integration_tests --dbt-version 1 --access public --contract-enforced true --require-model-version true --output "${EXPORT_OUTPUT}"
grep -q "contract_format_version: 1" "${EXPORT_OUTPUT}"
grep -q "kind: dbt" "${EXPORT_OUTPUT}"
grep -q "binding_version: 1" "${EXPORT_OUTPUT}"
grep -q "customer_id" "${EXPORT_OUTPUT}"
grep -q "order_amount" "${EXPORT_OUTPUT}"
grep -q "ordered_at" "${EXPORT_OUTPUT}"
if grep -q "name: SUM\\|name: DATE_TRUNC\\|name: month\\|name: COUNT\\|name: active" "${EXPORT_OUTPUT}"; then
  echo "Exporter leaked SQL function names or literals into required columns." >&2
  exit 1
fi
run_success "engine export contains only physical fixture columns" "${PYTHON[@]}" - "${EXPORT_OUTPUT}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = yaml.safe_load(handle)
resources = {
    resource["semantic_model_id"]: {column["name"] for column in resource["columns"]}
    for package in payload["semantic"]["packages"]
    for resource in package["resources"]
}
assert resources == {
    "customers": {"customer_id", "customer_name"},
    "revenue": {"customer_id", "order_amount", "order_id", "ordered_at", "status"},
}, resources
for names in resources.values():
    for name in names:
        assert not any(token in name for token in ("{", "}", "(", ")", "'", '"')), name
        assert name.lower() not in {"sum", "count", "date_trunc", "month", "active"}, name
assert "status_bucket" not in resources["revenue"]
PY
run_success "exporter delegates semantic production to engine API" "${PYTHON[@]}" - <<PY
import importlib.util
from pathlib import Path

path = Path("${ROOT_DIR}/scripts/export_semantic_rails_contract.py")
spec = importlib.util.spec_from_file_location("export_semantic_rails_contract", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

calls = []
def fake_exporter(path):
    calls.append(Path(path))
    return {
        "contract_format_version": 1,
        "semantic": {
            "producer": {"name": "semantic-rails", "version": "0.2.0"},
            "packages": [{
                "package_id": "semantic_fixture",
                "namespace": "semantic_fixture",
                "package_schema_version": 1,
                "semantic_hash": "sha256:engine-owned",
                "resources": [{
                    "semantic_model_id": "customers",
                    "relation": "customers",
                    "columns": [{"name": "customer_id", "required_by": ["entity.customer"]}],
                }],
            }],
        },
    }

args = module.parser().parse_args([
    "${EXPORT_FIXTURE}",
    "--dbt-package", "semantic_rails_contracts_integration_tests",
    "--dbt-version", "1",
])
payload = module.build_contract(args, exporter=fake_exporter)
assert calls == [Path("${EXPORT_FIXTURE}").resolve()]
assert payload["semantic"]["packages"][0]["semantic_hash"] == "sha256:engine-owned"
binding_resource = payload["binding"]["packages"][0]["resources"][0]
assert binding_resource["semantic_model_id"] == "customers"
assert "columns" not in binding_resource
assert not hasattr(module, "package_hash")
assert not hasattr(module, "load_package_documents")
PY
run_success "validate canonical and dbt-owned schema artifacts" "${PYTHON[@]}" - <<PY
import json
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from semantic_rails.contracts import contract_path, load_contract

root = Path("${ROOT_DIR}")
payload = yaml.safe_load(Path("${GOLDEN_CONTRACT}").read_text(encoding="utf-8"))
binding_schema = json.loads((root / "schemas/dbt_binding.v1.json").read_text(encoding="utf-8"))
composed_schema = json.loads(
    (root / "schemas/dbt_composed_contract.v1.json").read_text(encoding="utf-8")
)
semantic_schema = load_contract("semantic_contract.v1.json")
canonical_report_path = root / "schemas/validation_report.v1.json"
assert canonical_report_path.read_bytes() == contract_path("validation_report.v1.json").read_bytes()

for schema in (binding_schema, composed_schema):
    Draft202012Validator.check_schema(schema)
registry = (
    Registry()
    .with_resource(semantic_schema["\$id"], Resource.from_contents(semantic_schema))
    .with_resource(binding_schema["\$id"], Resource.from_contents(binding_schema))
)
Draft202012Validator(binding_schema).validate(payload["binding"])
Draft202012Validator(composed_schema, registry=registry).validate(payload)
PY
run_success "export Semantic Rails fixture as source contract" "${PYTHON[@]}" "${ROOT_DIR}/scripts/export_semantic_rails_contract.py" "${EXPORT_FIXTURE}" --dbt-package semantic_rails_contracts_integration_tests --dbt-resource-type source --dbt-source-name app --dbt-model-prefix raw_ --output "${SOURCE_EXPORT_OUTPUT}"
grep -q "dbt_resource_type: source" "${SOURCE_EXPORT_OUTPUT}"
grep -q "dbt_source_name: app" "${SOURCE_EXPORT_OUTPUT}"
grep -q "require_model_contract: false" "${SOURCE_EXPORT_OUTPUT}"
if grep -q "contract_enforced" "${SOURCE_EXPORT_OUTPUT}"; then
  echo "Source exports should not emit model-only contract_enforced fields." >&2
  exit 1
fi
run_failure "export source with model-only version option" "only apply to --dbt-resource-type model" "${PYTHON[@]}" "${ROOT_DIR}/scripts/export_semantic_rails_contract.py" "${EXPORT_FIXTURE}" --dbt-package semantic_rails_contracts_integration_tests --dbt-resource-type source --dbt-source-name app --dbt-version 1
else
  echo "==> skip engine-backed exporter checks (dbt runtime compatibility lane)"
fi

run_success "schema compatibility" "${PYTHON[@]}" "${ROOT_DIR}/scripts/check_schema_compatibility.py"
run_success "clean" "${DBT[@]}" clean --profiles-dir .
run_success "deps" "${DBT[@]}" deps --profiles-dir .
run_success "parse" "${DBT[@]}" parse --profiles-dir .
run_success "build" "${DBT[@]}" build --profiles-dir .
run_success "positive assertion from vars" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir .
GOLDEN_ARGS="$(contract_args valid)"
run_success "golden composed v1 assertion" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "${GOLDEN_ARGS}"
REPORT_OUTPUT="$("${DBT[@]}" run-operation semantic_rails_contract_report --profiles-dir .)"
if [[ "${REPORT_OUTPUT}" != *'"report_format_version": 1'* || "${REPORT_OUTPUT}" != *'"ok": true'* || "${REPORT_OUTPUT}" != *'"binding_version": 1'* ]]; then
  echo "ValidationReportV1 output is missing required versioned fields:" >&2
  echo "${REPORT_OUTPUT}" >&2
  exit 1
fi
REPORT_JSON="$(report_json_from_output "${REPORT_OUTPUT}")"
run_success "validate emitted dbt ValidationReportV1" "${PYTHON[@]}" - "${ROOT_DIR}" "${REPORT_JSON}" <<'PY'
import json
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator
from referencing import Registry, Resource

root = Path(sys.argv[1])
report = json.loads(sys.argv[2])
canonical = json.loads((root / "schemas/validation_report.v1.json").read_text(encoding="utf-8"))
dbt_report = json.loads(
    (root / "schemas/dbt_validation_report.v1.json").read_text(encoding="utf-8")
)
Draft202012Validator.check_schema(canonical)
Draft202012Validator.check_schema(dbt_report)
registry = Registry().with_resource(canonical["$id"], Resource.from_contents(canonical))
Draft202012Validator(canonical).validate(report)
Draft202012Validator(dbt_report, registry=registry).validate(report)
assert report["validator"]["version"] == str(
    yaml.safe_load((root / "dbt_project.yml").read_text(encoding="utf-8"))["version"]
)
assert report["summary"] == {
    "package_count": 1,
    "resource_count": 4,
    "error_count": 0,
    "warning_count": 0,
}
PY
UNSUPPORTED_REPORT_OUTPUT="$("${DBT[@]}" run-operation semantic_rails_contract_report --profiles-dir . --args "$(contract_args format2)")"
UNSUPPORTED_REPORT_JSON="$(report_json_from_output "${UNSUPPORTED_REPORT_OUTPUT}")"
MALFORMED_REPORT_OUTPUT="$("${DBT[@]}" run-operation semantic_rails_contract_report --profiles-dir . --args "$(contract_args format_string)")"
MALFORMED_REPORT_JSON="$(report_json_from_output "${MALFORMED_REPORT_OUTPUT}")"
run_success "validate unsupported and malformed version reports" "${PYTHON[@]}" - "${ROOT_DIR}" "${UNSUPPORTED_REPORT_JSON}" "${MALFORMED_REPORT_JSON}" <<'PY'
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator

root = Path(sys.argv[1])
schema = json.loads((root / "schemas/validation_report.v1.json").read_text(encoding="utf-8"))
unsupported = json.loads(sys.argv[2])
malformed = json.loads(sys.argv[3])
for report in (unsupported, malformed):
    Draft202012Validator(schema).validate(report)
    assert report["ok"] is False
    assert report["summary"]["error_count"] >= 1
    assert any(issue["code"] == "UNSUPPORTED_CONTRACT_FORMAT_VERSION" for issue in report["issues"])
assert unsupported["input"]["contract_format_version"] == 2
assert malformed["input"]["contract_format_version"] is None
PY
run_success "multi-project connector matrix" "${PYTHON[@]}" "${ROOT_DIR}/scripts/run_semantic_rails_contract_matrix.py" "${MATRIX_CONFIG}" --dbt-command "${DBT[*]}" --output "${MATRIX_OUTPUT}"
grep -q '"project_count": 2' "${MATRIX_OUTPUT}"
grep -q '"failed_count": 0' "${MATRIX_OUTPUT}"
run_failure "multi-project connector matrix drift" "DBT_COLUMN_MISSING" "${PYTHON[@]}" "${ROOT_DIR}/scripts/run_semantic_rails_contract_matrix.py" "${MATRIX_FAILURE_CONFIG}" --dbt-command "${DBT[*]}" --output "${MATRIX_FAILURE_OUTPUT}"
grep -q '"failed_count": 1' "${MATRIX_FAILURE_OUTPUT}"
run_success "single-package mapping-model contract shape" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {package_id: semantic_fixture, models: {customers: {dbt_model: customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 1, latest_version: 1, access: public, contract_enforced: true, columns: [{name: customer_id}]}}}}"
run_success "single-package resources-only source contract shape" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {package_id: semantic_fixture, resources: [{semantic_model_id: raw_customer_source, dbt_resource_type: source, dbt_source_name: app, dbt_source_table: raw_customers, dbt_package: semantic_rails_contracts_integration_tests, columns: [{name: customer_id}]}]}}"
run_success "single-package resources-only snapshot contract shape" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {package_id: semantic_fixture, resources: [{semantic_model_id: customer_seed_history, dbt_resource_type: snapshot, dbt_model: contract_seed_snapshot, dbt_package: semantic_rails_contracts_integration_tests, columns: [{name: seed_id}]}]}}"
run_success "warn-only mode" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{warn_only: true, contract: {packages: [{package_id: semantic_fixture, models: [{semantic_model_id: customers, dbt_model: customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 1, columns: [{name: missing_but_warn_only}]}]}]}}"

run_failure "empty contract" "INVALID_CONTRACT" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {}}"
run_failure "unsupported composed contract version" "UNSUPPORTED_CONTRACT_FORMAT_VERSION" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args format2)"
run_failure "string composed contract version" "UNSUPPORTED_CONTRACT_FORMAT_VERSION" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args format_string)"
run_failure "unsupported dbt binding version" "UNSUPPORTED_BINDING_VERSION" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args binding2)"
run_failure "string dbt binding version" "UNSUPPORTED_BINDING_VERSION" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args binding_string)"
run_failure "wrong binding kind" "BINDING_KIND_MISMATCH" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args wrong_kind)"
run_failure "unsupported package schema version" "UNSUPPORTED_PACKAGE_SCHEMA_VERSION" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args package_schema2)"
run_failure "malformed semantic hash" "INVALID_SEMANTIC_PACKAGE" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args malformed_hash)"
run_failure "malformed semantic columns" "INVALID_SEMANTIC_COLUMNS" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args malformed_columns)"
run_failure "missing semantic required_by" "INVALID_SEMANTIC_COLUMN" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args missing_required_by)"
run_failure "orphan dbt binding" "SEMANTIC_RESOURCE_NOT_FOUND" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args orphan_binding)"
run_failure "unknown composed top-level field" "INVALID_CONTRACT" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args unknown_top_level)"
run_failure "binding cannot redefine semantic columns" "INVALID_BINDING_RESOURCE" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args binding_contains_columns)"
run_failure "binding booleans must be booleans" "INVALID_BINDING_RESOURCE" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args binding_boolean_string)"
run_failure "dbt binding policy is required" "INVALID_BINDING_PACKAGE" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "$(contract_args missing_policy)"
run_failure "hash mismatch" "SEMANTIC_HASH_NOT_ACCEPTED" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, semantic_hash: sha256:old, accepted_semantic_hashes: [sha256:new], models: [{semantic_model_id: customers, dbt_model: customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 1, columns: [{name: customer_id}]}]}]}}"
run_failure "model not found" "DBT_MODEL_NOT_FOUND" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, models: [{semantic_model_id: customers, dbt_model: missing_model, dbt_package: semantic_rails_contracts_integration_tests, columns: [{name: customer_id}]}]}]}}"
run_failure "resource not found" "DBT_RESOURCE_NOT_FOUND" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, resources: [{semantic_model_id: raw_customer_source, dbt_resource_type: source, dbt_source_name: app, dbt_source_table: missing_source_table, dbt_package: semantic_rails_contracts_integration_tests, columns: [{name: customer_id}]}]}]}}"
run_failure "version mismatch" "DBT_MODEL_VERSION_MISMATCH" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, models: [{semantic_model_id: customers, dbt_model: customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 2, columns: [{name: customer_id}]}]}]}}"
run_failure "latest version mismatch" "DBT_LATEST_VERSION_MISMATCH" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, models: [{semantic_model_id: customers, dbt_model: customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 1, latest_version: 2, columns: [{name: customer_id}]}]}]}}"
run_failure "version required but missing" "DBT_MODEL_VERSION_MISSING" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, policy: {require_model_version: true}, models: [{semantic_model_id: unversioned_probe, dbt_model: unversioned_probe, dbt_package: semantic_rails_contracts_integration_tests, columns: [{name: id}]}]}]}}"
run_failure "access mismatch" "DBT_MODEL_ACCESS_MISMATCH" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, models: [{semantic_model_id: customers, dbt_model: customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 1, access: private, columns: [{name: customer_id}]}]}]}}"
run_failure "relation metadata mismatch" "DBT_RELATION_MISMATCH" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, models: [{semantic_model_id: customers, dbt_model: customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 1, dbt_alias: wrong_alias, columns: [{name: customer_id}]}]}]}}"
run_failure "source relation metadata mismatch" "DBT_RELATION_MISMATCH" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, resources: [{semantic_model_id: raw_customer_source, dbt_resource_type: source, dbt_source_name: app, dbt_source_table: raw_customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_schema: wrong_schema, columns: [{name: customer_id}]}]}]}}"
run_failure "contract not enforced" "DBT_CONTRACT_NOT_ENFORCED" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, models: [{semantic_model_id: unversioned_probe, dbt_model: unversioned_probe, dbt_package: semantic_rails_contracts_integration_tests, contract_enforced: true, columns: [{name: id}]}]}]}}"
run_failure "unsupported resource type" "INVALID_MODEL_CONTRACT" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, resources: [{semantic_model_id: customers, dbt_resource_type: exposure, dbt_model: customers, columns: [{name: customer_id}]}]}]}}"
run_failure "source with model-only governance fields" "INVALID_MODEL_CONTRACT" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, resources: [{semantic_model_id: raw_customer_source, dbt_resource_type: source, dbt_source_name: app, dbt_source_table: raw_customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 1, columns: [{name: customer_id}]}]}]}}"
run_failure "missing column" "DBT_COLUMN_MISSING" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, models: [{semantic_model_id: customers, dbt_model: customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 1, columns: [{name: definitely_missing_semantic_rails_column}]}]}]}}"
run_failure "exact type mismatch" "DBT_COLUMN_TYPE_MISMATCH" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, policy: {type_check: exact}, models: [{semantic_model_id: customers, dbt_model: customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 1, columns: [{name: customer_id, data_type: bigint}]}]}]}}"
run_failure "extra column disallowed" "DBT_COLUMN_EXTRA" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir . --args "{contract: {packages: [{package_id: semantic_fixture, policy: {allow_extra_columns: false}, models: [{semantic_model_id: customers, dbt_model: customers, dbt_package: semantic_rails_contracts_integration_tests, dbt_version: 1, columns: [{name: customer_id}]}]}]}}"

echo "Self-contained Semantic Rails dbt package integration matrix passed."
