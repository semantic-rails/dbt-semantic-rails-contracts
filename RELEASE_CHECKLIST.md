# Release Checklist

Before tagging a public release:

1. Update `dbt_project.yml` `version`.
2. Update `CHANGELOG.md`.
3. Run `./scripts/run_integration_tests.sh` from the package root.
4. In a separate dbt project, install via `packages.yml` using a local path or Git revision and run `dbt deps`.
5. Confirm `dbt run-operation semantic_rails_assert_contracts` passes for a real Semantic Rails contract payload.
6. Confirm a deliberate missing-column payload fails with `DBT_COLUMN_MISSING`.
7. When live connector credentials are available, run `scripts/run_live_adapter_smoke_tests.py` for each release-supported adapter and record pass/block status.
8. Create a Git tag that matches the documented package revision.

The public package is release-ready only when the self-contained integration
tests, at least one real dbt project harness, and all credentialed release
adapters that are not externally blocked by account state pass.
