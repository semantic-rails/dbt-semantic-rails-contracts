# dbt Semantic Rails Contracts

`semantic_rails_contracts` is a dbt package for checking that dbt resource
interfaces still satisfy the columns, model versions, access levels, relation
metadata, and contract expectations exported from a Semantic Rails package. It
is meant to be installed in any dbt project that backs, mirrors, or consumes a
versioned Semantic Rails configuration snapshot.

The package is intentionally dbt-native at runtime. dbt users install it with
`packages.yml`, commit a generated `vars.semantic_rails_contracts` payload into
their dbt project, then run a macro gate in CI:

```yaml
packages:
  - git: "https://github.com/semantic-rails/dbt-semantic-rails-contracts.git"
    revision: "v0.2.0"
```

Local development can use:

```yaml
packages:
  - local: ../dbt-semantic-rails-contracts
```

Then:

```shell
dbt deps
dbt build
dbt run-operation semantic_rails_assert_contracts
```

For Semantic Rails packages that span multiple connectors or dbt projects, run
one dbt invocation per project and aggregate the results:

```shell
python scripts/run_semantic_rails_contract_matrix.py \
  examples/semantic_rails_dbt_projects.yml
```

## Quickstart

Supported dbt version: `>=1.11.2, <2.0.0`. CI verifies the minimum supported
dbt Core release and the newest compatible 1.x release with DuckDB. The
dbt-native macro/runtime surface supports Python 3.10+. The optional exporter
uses the engine's public producer API and therefore requires Python 3.11+.

Required pull-request checks include a Python 3.10/dbt 1.11.2 runtime-only lane,
a Python 3.11 minimum-engine lane, and a latest compatible lane. While
`compatibility.json` declares the engine `release_state` as `candidate`, both
engine-backed lanes build and test only the exact approved
`engine_candidate_sha`. After that commit is tagged and published, maintainers
change the state to `released`; the same lanes then require
`semantic-rails==0.2.0` and `semantic-rails>=0.2,<0.3` from PyPI, with no source
fallback. A weekly advisory job tests engine `main` without making a moving
branch part of the release contract. Release order is engine first, then this
adapter.

[`compatibility.json`](compatibility.json) is the machine-readable release
contract. It records supported engine/dbt ranges, exact release-test versions,
contract ownership, the engine lifecycle state, the engine tag, and the
approved engine source commit. The adapter release remains blocked until the
state is `released` and the public engine tag resolves to that commit.

1. Install the package in your dbt project:

   ```yaml
   packages:
     - git: "https://github.com/semantic-rails/dbt-semantic-rails-contracts.git"
       revision: "v0.2.0"
   ```

2. Generate a contract payload from your Semantic Rails package:

   ```shell
   python dbt_packages/semantic_rails_contracts/scripts/export_semantic_rails_contract.py \
     /path/to/semantic_rails_package \
     --dbt-package my_dbt_project \
     --dbt-version 1 \
     --access public \
     --contract-enforced true \
     --require-model-version true \
     --output semantic_rails_contract.yml
   ```

   Export requires Python 3.11+ and `semantic-rails>=0.2,<0.3`. That dependency
   is used only by this authoring helper; dbt parse and runtime remain
   engine-independent.

3. Put the generated document under `vars.semantic_rails_contracts` in
   `dbt_project.yml`, or commit it as a separate YAML file for the matrix runner.

4. Ensure each exported dbt model has matching dbt properties:

   ```yaml
   models:
     - name: orders
       access: public
       latest_version: 1
       config:
         contract:
           enforced: true
       columns:
         - name: order_id
           data_type: varchar
       versions:
         - v: 1
   ```

5. Add the gate to CI after `dbt parse` or `dbt build`:

   ```shell
   dbt run-operation semantic_rails_assert_contracts
   ```

## Contract Shape

Add the exported payload under `vars` in `dbt_project.yml` or pass it to
`semantic_rails_assert_contracts --args`. Semantic Rails owns the canonical
semantic contract and package fingerprint. This repository owns only the dbt
binding and dbt graph enforcement:

- canonical semantic schema:
  `https://semantic-rails.com/schemas/semantic_contract.v1.json`
- canonical ValidationReport schema:
  `https://semantic-rails.com/schemas/validation_report.v1.json`
- [dbt binding schema](schemas/dbt_binding.v1.json)
- [composed dbt schema](schemas/dbt_composed_contract.v1.json)
- [dbt ValidationReport specialization](schemas/dbt_validation_report.v1.json)
- [vendored canonical ValidationReport compatibility copy](schemas/validation_report.v1.json)

The installed engine package and its checksummed GitHub Release assets are
authoritative for engine-owned contracts. The `semantic-rails.com/schemas/`
URLs are public mirrors of those exact released bytes. This repository resolves
composed schemas locally in CI and releases its adapter-owned schemas alongside
its compatibility and provenance manifests.

```yaml
vars:
  semantic_rails_contracts:
    contract_format_version: 1
    semantic:
      producer:
        name: semantic-rails
        version: 0.2.0
      packages:
        - package_id: jaffle_shop
          namespace: jaffle
          package_schema_version: 1
          semantic_hash: "sha256:..."
          resources:
            - semantic_model_id: orders
              relation: orders
              columns:
                - name: order_id
                  required_by: ["entity.order"]
                - name: ordered_at
                  required_by: ["time.ordered_at"]
    binding:
      kind: dbt
      binding_version: 1
      packages:
        - package_id: jaffle_shop
          policy:
            severity: error
            require_model_contract: true
            require_model_version: true
            type_check: ignore
          resources:
            - semantic_model_id: orders
              dbt_resource_type: model
              dbt_model: sr_orders
              dbt_package: jaffle_shop
              dbt_version: 1
              latest_version: 1
              access: public
              contract_enforced: true
```

The macro validates both halves, joins resources strictly by
`package_id + semantic_model_id`, and then checks the merged requirements
against dbt graph metadata. A missing, duplicated, malformed, or orphaned row is
an error; target bindings cannot redefine engine-owned required columns.

The legacy payload containing combined `packages/models/resources` remains
readable during the 0.x migration window and emits
`LEGACY_CONTRACT_FORMAT_DEPRECATED`. All repository tooling emits only composed
contract format v1. Legacy writing will be removed before 1.0.

## Export From Semantic Rails YAML

Use the helper script to ask the installed engine for the canonical semantic
contract, then add a dbt binding. The script never reparses or rehashes Semantic
Rails YAML itself. It is shipped in this repository and is also available after
`dbt deps` under `dbt_packages/semantic_rails_contracts/scripts/`.

```shell
python scripts/export_semantic_rails_contract.py \
  /path/to/configs/semantic_rails/jaffle_shop \
  --dbt-package jaffle_shop \
  --dbt-model-prefix sr_ \
  --dbt-version 1 \
  --access public \
  --contract-enforced true \
  --include-model orders \
  --include-model customers \
  --output semantic_rails_contract.yml
```

Put the generated YAML under `vars.semantic_rails_contracts`, or commit it as a
standalone contract for the matrix runner. `semantic_hash` is the engine-owned
identity of the exported package; this repository does not calculate it.

The exporter supports:

- any package layout supported by the installed Semantic Rails engine
- explicit `--model-map semantic_model=dbt_model` overrides
- model prefixes/suffixes for naming conventions
- selective export with repeated `--include-model`
- canonical engine producer and package fingerprint metadata
- `--dbt-resource-type source|seed|snapshot|model` for non-model mappings
- optional relation metadata with `--dbt-alias`, `--dbt-schema`,
  `--dbt-database`, `--dbt-identifier`, and `--dbt-relation-name`
- model-only governance export with `--dbt-version`, `--latest-version`,
  `--access`, `--contract-enforced`, and `--require-model-version`

## Mesh-Inspired Checks

The macro checks the parts of dbt Mesh governance that matter for consumers:

- the dbt model exists in the expected package
- source, seed, and snapshot resources can be checked when Semantic Rails maps
  to something other than a dbt model
- the expected dbt model version exists and is latest when requested
- public/protected/private access matches the contract
- `config.contract.enforced` is present when required
- optional relation metadata checks can pin `alias`, `schema`, `database`,
  `identifier`, or `relation_name`
- declared dbt columns include every Semantic Rails-required column
- optional type checks can be exact, compatible, or ignored
- the semantic and dbt binding packages/resources form an exact keyed join

The default posture is conservative: missing models/resources, missing columns,
model version drift, model access drift, disabled model contracts, and requested
relation metadata drift are errors. Extra dbt columns are allowed unless a
contract sets `allow_extra_columns: false`.

## Multiple dbt Projects

dbt has one active project/profile/target context for a command. A single
`dbt run-operation` should therefore validate the Semantic Rails contract slice
owned by that dbt project, not every warehouse connector in a Semantic Rails
deployment.

That limitation is exactly where Semantic Rails should sit above dbt. If a
Semantic Rails package maps to several connectors, use the matrix runner to call
dbt once per connector-backed project and fail CI when any project drifts:

```yaml
version: 1

defaults:
  profiles_dir: .
  run_deps: true
  run_parse: true

projects:
  - name: orders_warehouse
    project_dir: ../dbt-orders
    target: ci
    contract_file: semantic_rails_contract.yml

  - name: customers_warehouse
    project_dir: ../dbt-customers
    target: ci
    contract_file: semantic_rails_contract.yml
```

Then run:

```shell
python dbt_packages/semantic_rails_contracts/scripts/run_semantic_rails_contract_matrix.py \
  semantic_rails_dbt_projects.yml \
  --output target/semantic_rails_dbt_contract_matrix.json
```

Paths in the matrix are resolved from the matrix file for `project_dir`, and
from each project directory for `profiles_dir` and `contract_file`. Each project
can set its own `profile`, `target`, environment variables, and inline
`contract`. The runner continues across projects, writes an aggregate JSON
report when `--output` is supplied, and exits non-zero if any project fails.

This keeps the dbt package installable and dbt-native while preserving a
Semantic Rails advantage: one semantic package can be checked against many
physical dbt projects or warehouse connectors without pretending dbt has a
multi-connection runtime inside one project.

## Macro Reference

### `semantic_rails_assert_contracts`

Fails the dbt invocation when the declared Semantic Rails contract does not
match the dbt graph.

```shell
dbt run-operation semantic_rails_assert_contracts
```

Arguments:

- `contract`: optional contract payload. When omitted, the macro reads
  `vars.semantic_rails_contracts`.
- `var_name`: optional dbt var name. Defaults to `semantic_rails_contracts`.
- `warn_only`: when true, emits warnings instead of raising a compiler error.

### `semantic_rails_contract_report`

Prints a versioned JSON `ValidationReportV1` without failing the invocation.
The envelope includes `report_format_version`, `ok`, validator metadata, input
contract/binding versions, summary counts, and stable issue objects. This is the
machine-readable interface for CI and agents. It validates against the
engine-owned common report schema and this repository's dbt validator
specialization.

```shell
dbt run-operation semantic_rails_contract_report
```

### `semantic_rails_required_columns`

Optional generic test for relation-level column presence after a model is built.
The main macro checks dbt graph metadata; this test checks the live relation.

```yaml
models:
  - name: sr_orders
    tests:
      - semantic_rails_contracts.semantic_rails_required_columns:
          arguments:
            required_columns:
              - order_id
              - ordered_at
```

## Error Codes

The package emits stable error codes intended for CI parsing:

- `INVALID_CONTRACT`: missing or malformed contract payload
- `CONTRACT_FORMAT_VERSION_REQUIRED`: composed input omitted its format version
- `UNSUPPORTED_CONTRACT_FORMAT_VERSION`: unsupported composed format major
- `BINDING_VERSION_REQUIRED`: dbt binding omitted its version
- `UNSUPPORTED_BINDING_VERSION`: unsupported dbt binding major
- `BINDING_KIND_MISMATCH`: the supplied binding is not a dbt binding
- `PACKAGE_SCHEMA_VERSION_REQUIRED`: semantic package schema version omitted
- `UNSUPPORTED_PACKAGE_SCHEMA_VERSION`: unsupported semantic package schema major
- `INVALID_SEMANTIC_PACKAGE` / `INVALID_BINDING_PACKAGE`: malformed package row
- `INVALID_SEMANTIC_RESOURCE` / `INVALID_BINDING_RESOURCE`: malformed resource row
- `INVALID_SEMANTIC_COLUMNS` / `INVALID_SEMANTIC_COLUMN`: malformed engine-owned columns
- `DUPLICATE_SEMANTIC_PACKAGE` / `DUPLICATE_BINDING_PACKAGE`: duplicate package key
- `DUPLICATE_SEMANTIC_RESOURCE` / `DUPLICATE_BINDING_RESOURCE`: duplicate resource key
- `DUPLICATE_SEMANTIC_COLUMN`: duplicate semantic column name
- `SEMANTIC_PACKAGE_NOT_FOUND` / `DBT_BINDING_PACKAGE_NOT_FOUND`: package join mismatch
- `SEMANTIC_RESOURCE_NOT_FOUND` / `DBT_BINDING_RESOURCE_NOT_FOUND`: resource join mismatch
- `LEGACY_CONTRACT_FORMAT_DEPRECATED`: legacy payload was accepted during migration
- `UNSUPPORTED_LEGACY_CONTRACT_VERSION`: unsupported explicit legacy format version
- `INVALID_MODEL_CONTRACT`: malformed resource entry
- `SEMANTIC_HASH_NOT_ACCEPTED`: legacy-only accepted-hash gate failed
- `DBT_MODEL_NOT_FOUND`: expected dbt model is absent from the graph
- `DBT_RESOURCE_NOT_FOUND`: expected non-model dbt resource is absent from the graph
- `DBT_MODEL_AMBIGUOUS`: model name matched more than one dbt node
- `DBT_MODEL_VERSION_MISSING`: `require_model_version` is true and the dbt node is unversioned
- `DBT_MODEL_VERSION_MISMATCH`: expected dbt model version is not present
- `DBT_LATEST_VERSION_MISMATCH`: dbt `latest_version` differs from the contract
- `DBT_MODEL_ACCESS_MISMATCH`: dbt `access` differs from the contract
- `DBT_RELATION_MISMATCH`: dbt relation metadata differs from the contract
- `DBT_CONTRACT_NOT_ENFORCED`: dbt `config.contract.enforced` is not true
- `DBT_COLUMN_MISSING`: a Semantic Rails-required column is absent from dbt metadata
- `DBT_COLUMN_TYPE_MISMATCH`: optional type check failed
- `DBT_COLUMN_EXTRA`: `allow_extra_columns: false` and dbt declares an unlisted column

## Verification

The package repository contains a self-contained dbt integration project:

```shell
./scripts/run_integration_tests.sh
```

That script installs this package with `dbt deps`, parses a fixture project,
exports a Semantic Rails fixture through the engine-owned producer API, validates
the dbt binding schema and golden composed fixture, builds a versioned dbt model,
source, seed, and snapshot fixture, verifies `ValidationReportV1`, exercises
legacy dual-read, runs a two-project connector matrix, and verifies targeted
negative cases for the error codes above.

The companion Jaffle harness at `../semantic-rails-dbt-jaffle` is a broader
real-data smoke test:

```shell
cd ../semantic-rails-dbt-jaffle
./scripts/verify_semantic_rails_contracts.sh
```

Live adapter smoke tests are available when connector credentials are present:

```shell
python scripts/run_live_adapter_smoke_tests.py \
  --env-file /path/to/env_setup.txt \
  --adapter athena \
  --adapter bigquery \
  --adapter databricks \
  --adapter snowflake \
  --output target/live_adapter_smoke/report.json
```

The live harness generates temporary dbt projects under `target/`, installs this
package locally, runs `dbt deps`, `dbt debug`, a one-row `dbt build`, the
`semantic_rails_assert_contracts` operation, and a best-effort cleanup macro for
each selected adapter. It supports Athena, BigQuery, Databricks, MotherDuck,
Redshift, and Snowflake. Missing credentials are skipped; account-state failures
remain failures because they are real connector readiness issues.

## Scope And Limits

This package verifies the dbt side of the contract: model/source/seed/snapshot
existence, model version, latest version, access, dbt model contract
enforcement, relation metadata, column presence, optional column type metadata,
optional extra-column strictness, keyed semantic/binding composition, aggregate status
across multiple dbt projects when the external matrix runner is used, and live
adapter readiness when the optional live harness is run.

The main assertion macro is adapter-independent because it checks dbt graph
metadata, not warehouse SQL. The optional `semantic_rails_required_columns` data
test uses `adapter.get_columns_in_relation` and should be run in projects where
your adapter supports relation column introspection.

This package does not prove that a dbt SQL model is semantically equivalent to
the full Semantic Rails query runtime. It does not execute Semantic Rails
queries, compare metric outputs, or parse arbitrary SQL expressions inside dbt.
Use it as a CI compatibility gate between a versioned Semantic Rails config
snapshot and the dbt models that are supposed to back that snapshot.
