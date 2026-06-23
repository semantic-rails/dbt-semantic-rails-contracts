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

if [[ -n "${DBT_BIN:-}" ]]; then
  DBT=("${DBT_BIN}")
elif command -v dbt >/dev/null 2>&1; then
  DBT=(dbt)
elif command -v uv >/dev/null 2>&1; then
  DBT=(uv run --with "dbt-core>=1.11,<2.0" --with "dbt-duckdb>=1.10,<2.0" dbt)
else
  echo "dbt is not installed. Install requirements-dev.txt or install uv." >&2
  exit 1
fi

if [[ -n "${PYTHON_BIN:-}" ]]; then
  PYTHON=("${PYTHON_BIN}")
elif command -v uv >/dev/null 2>&1; then
  PYTHON=(uv run --with "PyYAML>=6.0" --with "sqlglot>=25.0" python)
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

cd "${PROJECT_DIR}"

run_success "export Semantic Rails fixture" "${PYTHON[@]}" "${ROOT_DIR}/scripts/export_semantic_rails_contract.py" "${EXPORT_FIXTURE}" --dbt-package semantic_rails_contracts_integration_tests --dbt-version 1 --access public --contract-enforced true --require-model-version true --output "${EXPORT_OUTPUT}"
grep -q "semantic_rails_contracts:" "${EXPORT_OUTPUT}"
grep -q "customer_id" "${EXPORT_OUTPUT}"
grep -q "order_amount" "${EXPORT_OUTPUT}"
grep -q "ordered_at" "${EXPORT_OUTPUT}"
if grep -q "name: SUM\\|name: DATE_TRUNC\\|name: month\\|name: COUNT\\|name: active" "${EXPORT_OUTPUT}"; then
  echo "Exporter leaked SQL function names or literals into required columns." >&2
  exit 1
fi
run_success "export helper expression and hash behavior" "${PYTHON[@]}" - <<PY
import importlib.util
from pathlib import Path

path = Path("${ROOT_DIR}/scripts/export_semantic_rails_contract.py")
spec = importlib.util.spec_from_file_location("export_semantic_rails_contract", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

assert module.columns_from_expr("SUM(order_amount)") == {"order_amount"}
assert module.columns_from_expr("COUNT(DISTINCT customer_id)") == {"customer_id"}
assert module.columns_from_expr("DATE_TRUNC('month', orders.ordered_at)") == {"ordered_at"}
assert module.columns_from_expr("CASE WHEN status = 'active' THEN order_amount ELSE 0 END") == {"status", "order_amount"}

fixture = Path("${EXPORT_FIXTURE}")
assert any(path.suffix == ".yaml" for path in module.iter_package_yaml_files(fixture))
before = module.package_hash(fixture)
(fixture / "semantic_rails_contract.yml").write_text("generated: true\\n", encoding="utf-8")
try:
    assert module.package_hash(fixture) == before
finally:
    (fixture / "semantic_rails_contract.yml").unlink()
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

run_success "deps" "${DBT[@]}" deps --profiles-dir .
run_success "parse" "${DBT[@]}" parse --profiles-dir .
run_success "build" "${DBT[@]}" build --profiles-dir .
run_success "positive assertion from vars" "${DBT[@]}" run-operation semantic_rails_assert_contracts --profiles-dir .
run_success "report macro" "${DBT[@]}" run-operation semantic_rails_contract_report --profiles-dir .
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
