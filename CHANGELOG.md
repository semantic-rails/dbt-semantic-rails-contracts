# Changelog

## Unreleased

- The export helper and the engine-backed CI lanes require
  `semantic-rails>=0.3,<0.4` (engine 0.3.0).
- CI checks the engine's metric portability corpus against the native dbt
  validation binding.
- `compatible` type checks accept a `uuid` column for `string` (and a string
  column for `uuid`), and a zoned column (`timestamptz`,
  `timestamp with time zone`, `timestamp_tz`) for `timestamp`. A `timestamp_tz`
  requirement needs a zoned column. `exact` is unchanged.
- Macro argument types in `macros/schema.yml` use dbt's type names, so dbt 1.12
  parses the package without warnings.
- `run_semantic_rails_contract_matrix.py --contract-file` checks one dbt project
  against a committed contract file.
- The README installs from `main` until `v0.2.0` is tagged.
  `compatibility.json` records `package.release_state`, and
  `verify_release_metadata.py` rejects a documented install revision that is
  not yet published.

## 0.2.0

- Adds strict composed contract format v1 and dbt binding v1 validation.
- Joins engine-owned semantic requirements to dbt bindings by package and
  semantic model identifiers.
- Delegates semantic parsing and fingerprinting to the public Semantic Rails
  producer API.
- Adds `ValidationReportV1`, schemas, golden fixtures, and stable version and
  composition error codes.
- Preserves legacy combined payload reads with an explicit deprecation warning;
  all tooling now writes composed v1.
- Adds minimum/latest dbt compatibility CI, immutable engine-candidate
  qualification, and a build-once verified tag release workflow.
- Adds machine-readable compatibility and release-provenance manifests tying
  adapter artifacts to the exact approved engine commit and wheel.
- Uses dbt Core 1.11.2 as the minimum supported release because 1.11.0 and
  1.11.1 were yanked for installation issues.

## 0.1.0

Initial public release candidate.

- Adds `semantic_rails_assert_contracts` for dbt graph contract checks.
- Adds `semantic_rails_contract_report` for non-failing adoption reports.
- Adds `semantic_rails_required_columns` as an optional live relation test.
- Adds `scripts/export_semantic_rails_contract.py` for generating dbt vars from Semantic Rails YAML.
- Adds integration tests covering positive and negative contract drift cases.
- Adds support for dbt source, seed, and snapshot graph resources plus optional relation metadata checks.
- Adds `scripts/run_semantic_rails_contract_matrix.py` for aggregating contract checks across multiple dbt projects/connectors.
- Adds `scripts/run_live_adapter_smoke_tests.py` for optional live connector smoke tests across Athena, BigQuery, Databricks, MotherDuck, Redshift, and Snowflake.
