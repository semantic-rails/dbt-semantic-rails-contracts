{% test semantic_rails_required_columns(model, required_columns) %}
  {% set required = semantic_rails_contracts.semantic_rails_expected_columns(required_columns) %}
  {% set missing = [] %}

  {% if execute %}
    {% set relation_columns = adapter.get_columns_in_relation(model) %}
    {% set actual_names = [] %}
    {% for column in relation_columns %}
      {% do actual_names.append(column.name | lower) %}
    {% endfor %}
    {% for column in required %}
      {% if (column.get('name') | lower) not in actual_names %}
        {% do missing.append(column.get('name')) %}
      {% endif %}
    {% endfor %}
  {% endif %}

  {% if missing | length == 0 %}
    select null as missing_column where false
  {% else %}
    {% for column_name in missing %}
      select '{{ column_name }}' as missing_column
      {% if not loop.last %}union all{% endif %}
    {% endfor %}
  {% endif %}
{% endtest %}
