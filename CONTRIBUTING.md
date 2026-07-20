# Contributing

This is a dbt package. Keep runtime behavior dbt-native: macros should inspect
dbt graph metadata and user-provided vars rather than importing Python packages
or reading external files during dbt parse.

Semantic Rails owns the semantic contract schema, common validation-report
schema, and producer. Do not fork those contracts or copy the loader or
fingerprint implementation here. A vendored compatibility schema must remain
byte-identical to the engine artifact and have a CI drift check. The authoring
helper may call the public
`semantic_rails.contracts.export_semantic_contract` API outside dbt; runtime
macros must remain independent.

## Local Verification

```shell
python -m pip install -r requirements-dev.txt
./scripts/run_integration_tests.sh
```

If `uv` is installed, the script can provision its own temporary dbt/PyYAML
environment.

The macro runtime supports Python 3.10, but the engine-backed exporter follows
the engine floor of Python 3.11. Set `SKIP_EXPORT_TESTS=true` only for the
dedicated Python 3.10 runtime lane; release and candidate lanes must exercise
the exporter against an exact engine artifact.

## Release Rules

- Keep `dbt_project.yml` version aligned with `CHANGELOG.md`.
- Add or update integration tests for every new error code.
- Preserve stable error-code strings unless the changelog calls out a breaking change.
- Classify contract changes as `none`, `additive`, or `breaking`.
- Update the dbt binding schema, golden fixture, and compatibility tests together.
- Add dual-read support before any producer starts emitting a new major version.
- Do not add adapter-specific SQL to the main assertion macro.
- Keep `compatibility.json` aligned with dbt metadata, owned schema IDs, and
  exact release-test versions.
- Qualify an immutable engine commit, release the engine first, and require the
  engine tag to resolve to that approved commit before tagging this adapter.
