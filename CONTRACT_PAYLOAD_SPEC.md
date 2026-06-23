# Semantic Rails Contract Payload Spec

This file defines the payload shape shared by the dbt and SQLMesh Semantic
Rails contract packages. Each implementation validates the same package,
resource, column, policy, and hash concepts, then adds framework-native fields
for dbt or SQLMesh metadata.

## Top-Level Shape

The payload can be stored directly in a YAML file or nested under
`semantic_rails_contracts`.

```yaml
semantic_rails_contracts:
  packages:
    - package_id: jaffle_shop
      namespace: jaffle
      contract_version: 1
      semantic_hash: sha256:...
      accepted_semantic_hashes:
        - sha256:...
      policy:
        severity: error
        type_check: compatible
        allow_extra_columns: true
      models: []
      resources: []
```

`models` is the common path for model-backed Semantic Rails resources.
`resources` is the explicit path for sources, seeds, snapshots, external tables,
or any resource where the physical implementation should be named directly.
Both lists use the same row shape.

## Package Fields

- `package_id`: stable package identifier used in issue output
- `namespace`: optional Semantic Rails namespace
- `contract_version`: payload format version
- `semantic_hash`: hash of the exported Semantic Rails package snapshot
- `accepted_semantic_hashes`: migration window for known-compatible snapshots
- `policy`: package defaults for resource checks
- `models` / `resources`: resource contract rows

If `accepted_semantic_hashes` is present and does not include `semantic_hash`,
the checker must emit `SEMANTIC_HASH_NOT_ACCEPTED`.

## Policy Fields

- `severity`: `error` or `warn`
- `type_check`: `ignore`, `compatible`, or `exact`
- `allow_extra_columns`: when false, declared physical columns must be exactly
  the Semantic Rails-required column set
- `require_model_contract`: dbt model-contract enforcement default
- `require_model_version`: dbt model-version enforcement default
- `require_owner`: SQLMesh owner enforcement default
- `require_audits`: SQLMesh audit enforcement default

Resource rows may override policy fields when the implementation supports the
override.

## Resource Fields

Common fields:

- `semantic_model_id`: Semantic Rails model or resource identifier
- `columns`: required physical columns
- `severity`, `type_check`, `allow_extra_columns`: optional row-level overrides

dbt fields:

- `dbt_resource_type`: `model`, `source`, `seed`, or `snapshot`
- `dbt_model`, `dbt_source_name`, `dbt_source_table`
- `dbt_package`, `dbt_version`, `latest_version`, `access`
- `contract_enforced`
- `dbt_alias`, `dbt_schema`, `dbt_database`, `dbt_identifier`,
  `dbt_relation_name`

SQLMesh fields:

- `sqlmesh_model`: SQLMesh model name, preferably fully qualified
- `sqlmesh_project`, `sqlmesh_gateway`, `sqlmesh_kind`
- `sqlmesh_external` / `external`
- `owner`
- `tags` / `sqlmesh_tags`
- `audits` / `sqlmesh_audits`
- `sqlmesh_catalog`, `sqlmesh_schema`, `sqlmesh_identifier`,
  `sqlmesh_relation_name`

Implementations may accept compatibility aliases such as `model`, `dbt_name`,
or `sqlmesh_name`, but generated contracts should use framework-specific names.

## Column Fields

```yaml
columns:
  - name: customer_id
    data_type: integer
    required_by:
      - entity.customer
```

- `name`: required physical column name
- `data_type`: optional expected type
- `required_by`: optional Semantic Rails entity, dimension, measure, or time
  field references that explain why the column is required

Column name comparison is case-insensitive. Type comparison is controlled by
`type_check`: `ignore` skips type validation, `compatible` allows common
cross-warehouse aliases, and `exact` requires the serialized physical type to
match the exported type.

## Multi-Project Use

dbt supports one active connection context per invocation. SQLMesh supports
gateways, but each check still validates one loaded SQLMesh context. Semantic
Rails packages that span connectors should use the package-specific matrix
runner and one contract slice per physical project or gateway.

