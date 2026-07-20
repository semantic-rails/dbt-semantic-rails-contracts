# Release Checklist

Before tagging a public release:

1. Update `dbt_project.yml` `version`.
2. Update `CHANGELOG.md`.
3. Confirm the exact-SHA engine qualification workflow passed and record that
   40-character commit in `compatibility.json`. Before publication, keep
   `engine.release_state` set to `candidate` so ordinary CI builds only that
   immutable revision.
4. Confirm the canonical Semantic Rails producer release required by this
   adapter is published, its semantic schema major is supported, and its tag
   resolves to the approved commit. Then change `engine.release_state` to
   `released` and require ordinary CI to pass against the PyPI artifact.
5. Validate `schemas/dbt_binding.v1.json`, the composed and dbt report schema
   references, the byte-identical canonical report compatibility copy, and
   `integration_tests/contracts/golden_composed_v1.yml`. Run
   `scripts/check_schema_compatibility.py` and confirm released v1 schema shapes
   remain identical to the immutable baseline.
6. Run `./scripts/run_integration_tests.sh` from the package root against the
   released engine package.
7. Confirm the minimum-engine/minimum-dbt and latest-engine/latest-dbt required
   CI lanes pass.
8. In a separate dbt project, install via `packages.yml` using a local path or
   Git revision and run `dbt deps`.
9. Confirm `semantic_rails_assert_contracts` passes for a freshly exported
   composed v1 payload and `semantic_rails_contract_report` emits a valid
   `ValidationReportV1`.
10. Confirm version, malformed-row, orphan-binding, and deliberate
   missing-column payloads fail with their documented stable codes.
11. When live connector credentials are available, run
    `scripts/run_live_adapter_smoke_tests.py` for each release-supported adapter
    and record pass/block status.
12. Run `scripts/verify_release_metadata.py --verify-engine-tag` and confirm the
    public engine tag resolves to the approved engine commit.
13. Confirm the `release` environment and protected tag/ruleset require an
    authorized maintainer.
14. Create an annotated `vX.Y.Z` tag matching `dbt_project.yml`; the release
    workflow archives once, tests the exact source archive against the exact
    engine wheel, emits checksums and provenance, then publishes those verified
    bytes in the GitHub Release.

The public package is release-ready only when the self-contained integration
tests, compatibility matrix, contract conformance gates, at least one real dbt
project harness, and all credentialed release adapters that are not externally
blocked by account state pass.
