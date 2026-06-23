{% snapshot contract_seed_snapshot %}
  {{
    config(
      target_schema='main',
      unique_key='seed_id',
      strategy='check',
      check_cols=['seed_name']
    )
  }}

  select seed_id, seed_name
  from {{ ref('contract_seed') }}
{% endsnapshot %}
