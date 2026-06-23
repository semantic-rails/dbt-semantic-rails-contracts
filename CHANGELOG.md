# Changelog

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
