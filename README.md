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
    revision: "v0.1.0"
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

Supported dbt version: `>=1.11.0, <2.0.0`. The release verification currently
runs on dbt Core 1.11 with DuckDB for integration coverage.

1. Install the package in your dbt project:

   ```yaml
   packages:
     - git: "https://github.com/semantic-rails/dbt-semantic-rails-contracts.git"
       revision: "v0.1.0"
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

3. Copy the generated `semantic_rails_contracts:` block under `vars:` in
   `dbt_project.yml`.

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
`semantic_rails_assert_contracts --args`. See
[CONTRACT_PAYLOAD_SPEC.md](CONTRACT_PAYLOAD_SPEC.md) for the cross-package
schema shared with the SQLMesh package.

```yaml
vars:
  semantic_rails_contracts:
    packages:
      - package_id: jaffle_shop
        namespace: jaffle
        contract_version: 1
        semantic_hash: "sha256:..."
        accepted_semantic_hashes:
          - "sha256:..."
        policy:
          severity: error
          require_model_contract: true
          require_model_version: true
          type_check: ignore
        models:
          - semantic_model_id: orders
            dbt_resource_type: model
            dbt_model: sr_orders
            dbt_package: jaffle_shop
            dbt_version: 1
            latest_version: 1
            access: public
            contract_enforced: true
            allow_extra_columns: true
            columns:
              - name: order_id
                required_by: ["entity.order"]
              - name: ordered_at
                required_by: ["time.ordered_at"]
        resources:
          - semantic_model_id: raw_orders
            dbt_resource_type: source
            dbt_source_name: app
            dbt_source_table: raw_orders
            dbt_package: jaffle_shop
            dbt_schema: raw
            columns:
              - name: order_id
              - name: ordered_at
```

The package treats this payload as a compatibility contract, not as a complete
Semantic Rails parser. That is deliberate: dbt parsing should not import a
Python runtime or read arbitrary external files. Generate the payload outside
dbt, commit it, and make dbt enforce the shape it owns.

`models:` is retained for the common dbt-model mapping and defaults to
`dbt_resource_type: model`. Use `resources:` when a Semantic Rails model maps to
a dbt `source`, `seed`, or `snapshot`, or when you want the contract to make the
resource type explicit. Model governance fields (`dbt_version`,
`latest_version`, `access`, `require_model_version`, and `contract_enforced`)
only apply to `dbt_resource_type: model`.

## Export From Semantic Rails YAML

Use the helper script to generate a vars block from a Semantic Rails package.
The script is shipped in this repository and is also available after `dbt deps`
under `dbt_packages/semantic_rails_contracts/scripts/`.

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

Copy the generated YAML under `vars:` in the dbt project, or merge it with an
environment-specific overlay. The `semantic_hash` lets dbt projects pin known
Semantic Rails config snapshots while still allowing a migration window through
`accepted_semantic_hashes`.

The exporter supports:

- directory or single-file Semantic Rails packages
- explicit `--model-map semantic_model=dbt_model` overrides
- model prefixes/suffixes for naming conventions
- selective export with repeated `--include-model`
- package hash pinning through `semantic_hash`
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
- optional `accepted_semantic_hashes` pins a Semantic Rails config snapshot

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

Prints a JSON issue report without failing the invocation. This is useful while
adopting contracts incrementally.

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
- `INVALID_MODEL_CONTRACT`: malformed resource entry
- `SEMANTIC_HASH_NOT_ACCEPTED`: Semantic Rails hash is outside the allowed set
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
exports a Semantic Rails fixture package, builds a versioned dbt model, source,
seed, and snapshot fixture, runs the positive assertion, runs the report and
generic test paths, verifies a two-project connector matrix, verifies warn-only
mode, and verifies targeted negative cases for the error codes above.

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
optional extra-column strictness, Semantic Rails hash pinning, aggregate status
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
