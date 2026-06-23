# Contributing

This is a dbt package. Keep runtime behavior dbt-native: macros should inspect
dbt graph metadata and user-provided vars rather than importing Python packages
or reading external files during dbt parse.

## Local Verification

```shell
python -m pip install -r requirements-dev.txt
./scripts/run_integration_tests.sh
```

If `uv` is installed, the script can provision its own temporary dbt/PyYAML
environment.

## Release Rules

- Keep `dbt_project.yml` version aligned with `CHANGELOG.md`.
- Add or update integration tests for every new error code.
- Preserve stable error-code strings unless the changelog calls out a breaking change.
- Do not add adapter-specific SQL to the main assertion macro.
