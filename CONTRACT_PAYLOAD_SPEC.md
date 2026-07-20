# dbt Binding Contract

Semantic Rails is the sole authority for the shared semantic contract:

- schema ID: `https://semantic-rails.com/schemas/semantic_contract.v1.json`
- packaged engine schema:
  `semantic_rails/contracts/semantic_contract.v1.json`
- producer API:
  `semantic_rails.contracts.export_semantic_contract(path)`

This repository does not copy the semantic schema, parse Semantic Rails project
YAML, or calculate package fingerprints. It owns:

- [`schemas/dbt_binding.v1.json`](schemas/dbt_binding.v1.json)
- [`schemas/dbt_composed_contract.v1.json`](schemas/dbt_composed_contract.v1.json)
- [`schemas/dbt_validation_report.v1.json`](schemas/dbt_validation_report.v1.json)
- dbt graph validation and stable dbt error codes

[`schemas/validation_report.v1.json`](schemas/validation_report.v1.json) is a
byte-identical compatibility copy of the engine-owned common report schema, not
a second authority. CI checks it for drift.

## Composition

The abbreviated shape below shows ownership only; empty package arrays are not
a valid emitted payload:

```yaml
contract_format_version: 1
semantic: # emitted by Semantic Rails
  producer:
    name: semantic-rails
    version: 0.2.0
  packages: []
binding: # emitted and enforced by this package
  kind: dbt
  binding_version: 1
  packages: []
```

The validator joins semantic and binding packages by `package_id`, then joins
resources by `semantic_model_id`. Semantic columns always come from the engine
section. dbt bindings name physical dbt resources and governance expectations;
they cannot replace semantic columns.

Unknown top-level fields, unsupported versions, malformed rows or columns,
duplicates, missing matches, and orphaned bindings fail closed with stable error
codes.

## Compatibility

`contract_format_version` and `binding_version` are independent major versions.
Once a schema ID is released, its accepted shape is immutable; extensions use a
new versioned schema and dual-read migration instead of editing v1 in place.

The released adapter-owned v1 schemas are frozen under
`compatibility/baseline/v1`. CI compares their parsed JSON to the working
schemas and rejects any in-place change. A contract-shape change therefore
requires a new schema major and an explicit dual-read migration.

The pre-v1 combined `packages/models/resources` payload is accepted temporarily
and emits `LEGACY_CONTRACT_FORMAT_DEPRECATED`. Export tooling writes only the
composed v1 format. Legacy write support will not be part of 1.0.

Required adapter CI is pinned to released engine versions. Engine `main` is
tested only in a scheduled advisory canary. An explicit workflow dispatch can
qualify only an exact 40-character engine commit. Release is blocked until that
qualified commit is recorded in `compatibility.json` and the public engine tag
resolves to the same commit.

The installed `semantic-rails` package and engine GitHub Release are the
authoritative sources for engine-owned schema bytes. The
`semantic-rails.com/schemas/` locations are public mirrors. Adapter releases
include their owned schemas, the compatibility manifest, and a provenance
record tying the tested source archive to the exact engine wheel and commit.
