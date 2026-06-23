{% macro semantic_rails_assert_contracts(contract=none, var_name='semantic_rails_contracts', warn_only=false) %}
  {% if not execute %}
    {{ return([]) }}
  {% endif %}

  {% set spec = contract if contract is not none else var(var_name, {}) %}
  {% set issues = semantic_rails_collect_contract_issues(spec) %}
  {% set errors = [] %}
  {% set warnings = [] %}

  {% for issue in issues %}
    {% if issue.get('severity', 'error') == 'warn' %}
      {% do warnings.append(issue) %}
    {% else %}
      {% do errors.append(issue) %}
    {% endif %}
  {% endfor %}

  {% for issue in warnings %}
    {% do exceptions.warn(semantic_rails_format_contract_issue(issue)) %}
  {% endfor %}

  {% if errors | length > 0 %}
    {% set lines = [] %}
    {% for issue in errors %}
      {% do lines.append(semantic_rails_format_contract_issue(issue)) %}
    {% endfor %}
    {% set message = "Semantic Rails contract check failed with " ~ (errors | length) ~ " error(s):\n" ~ (lines | join("\n")) %}
    {% if warn_only | as_bool %}
      {% do exceptions.warn(message) %}
    {% else %}
      {% do exceptions.raise_compiler_error(message) %}
    {% endif %}
  {% endif %}

  {% set summary = semantic_rails_contract_summary(spec) %}
  {% set resource_count = summary.get('resource_count', summary.get('model_count')) %}
  {% if errors | length > 0 and warn_only | as_bool %}
    {% do print("Semantic Rails contract check completed with " ~ (errors | length) ~ " warn-only error(s) for " ~ resource_count ~ " resource contract(s) across " ~ summary.get('package_count') ~ " package(s).") %}
  {% elif warnings | length > 0 %}
    {% do print("Semantic Rails contract check passed with " ~ (warnings | length) ~ " warning(s) for " ~ resource_count ~ " resource contract(s) across " ~ summary.get('package_count') ~ " package(s).") %}
  {% else %}
    {% do print("Semantic Rails contract check passed for " ~ resource_count ~ " resource contract(s) across " ~ summary.get('package_count') ~ " package(s).") %}
  {% endif %}
  {{ return(issues) }}
{% endmacro %}


{% macro semantic_rails_contract_report(contract=none, var_name='semantic_rails_contracts') %}
  {% if not execute %}
    {{ return([]) }}
  {% endif %}

  {% set spec = contract if contract is not none else var(var_name, {}) %}
  {% set issues = semantic_rails_collect_contract_issues(spec) %}
  {% do print(tojson({"summary": semantic_rails_contract_summary(spec), "issues": issues})) %}
  {{ return(issues) }}
{% endmacro %}


{% macro semantic_rails_collect_contract_issues(spec) %}
  {% set issues = [] %}

  {% if spec is not mapping or (spec | length) == 0 %}
    {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'vars.semantic_rails_contracts must be a non-empty mapping.')) %}
    {{ return(issues) }}
  {% endif %}

  {% set packages = semantic_rails_contract_packages(spec) %}
  {% if packages | length == 0 %}
    {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'No Semantic Rails packages were declared. Use packages: [...] or a single package payload with models: or resources:.')) %}
    {{ return(issues) }}
  {% endif %}

  {% for package_contract in packages %}
    {% if package_contract is not mapping %}
      {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'Each packages entry must be a mapping.')) %}
    {% else %}
      {% set package_id = package_contract.get('package_id', package_contract.get('id', package_contract.get('name', ''))) %}
      {% set policy = package_contract.get('policy', {}) %}
      {% set severity = policy.get('severity', 'error') %}
      {% set semantic_hash = package_contract.get('semantic_hash') %}
      {% set accepted_hashes = package_contract.get('accepted_semantic_hashes', []) %}
      {% if accepted_hashes and semantic_hash not in accepted_hashes %}
        {% do issues.append(semantic_rails_issue('SEMANTIC_HASH_NOT_ACCEPTED', severity, package_id, '', 'Semantic Rails package hash ' ~ semantic_hash ~ ' is not in accepted_semantic_hashes.')) %}
      {% endif %}

      {% set resource_contracts = semantic_rails_contract_entries(package_contract) %}
      {% if resource_contracts | length == 0 %}
        {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', severity, package_id, '', 'Package declares no resource contracts. Use models: or resources:.')) %}
      {% endif %}

      {% for resource_contract in resource_contracts %}
        {% set resource_issues = semantic_rails_validate_model_contract(package_contract, resource_contract) %}
        {% for issue in resource_issues %}
          {% do issues.append(issue) %}
        {% endfor %}
      {% endfor %}
    {% endif %}
  {% endfor %}

  {{ return(issues) }}
{% endmacro %}


{% macro semantic_rails_validate_model_contract(package_contract, model_contract) %}
  {% set issues = [] %}
  {% set policy = package_contract.get('policy', {}) %}
  {% set severity = model_contract.get('severity', policy.get('severity', 'error')) %}
  {% set package_id = package_contract.get('package_id', package_contract.get('id', package_contract.get('name', ''))) %}
  {% set semantic_model_id = model_contract.get('semantic_model_id', model_contract.get('id', model_contract.get('name', ''))) %}
  {% set resource_type = model_contract.get('dbt_resource_type', model_contract.get('resource_type', 'model')) %}
  {% set dbt_model = model_contract.get('dbt_model', model_contract.get('dbt_name', semantic_model_id)) %}
  {% set dbt_package = model_contract.get('dbt_package', package_contract.get('dbt_package', project_name)) %}
  {% set expected_version = model_contract.get('dbt_version', model_contract.get('version')) %}
  {% set expected_latest = model_contract.get('latest_version') %}
  {% set expected_access = model_contract.get('access') %}
  {% set require_model_contract = model_contract.get('require_model_contract', policy.get('require_model_contract', true)) %}
  {% set expected_contract_enforced = model_contract.get('contract_enforced', require_model_contract if resource_type == 'model' else false) %}
  {% set require_model_version = model_contract.get('require_model_version', policy.get('require_model_version', false) if resource_type == 'model' else false) %}
  {% set allow_extra_columns = model_contract.get('allow_extra_columns', policy.get('allow_extra_columns', true)) %}
  {% set type_check = model_contract.get('type_check', policy.get('type_check', 'ignore')) %}
  {% set supported_resource_types = ['model', 'source', 'seed', 'snapshot'] %}

  {% if resource_type not in supported_resource_types %}
    {% do issues.append(semantic_rails_issue('INVALID_MODEL_CONTRACT', severity, package_id, semantic_model_id, 'Unsupported dbt_resource_type ' ~ resource_type ~ '. Supported values: model, source, seed, snapshot.')) %}
    {{ return(issues) }}
  {% endif %}

  {% if not dbt_model %}
    {% do issues.append(semantic_rails_issue('INVALID_MODEL_CONTRACT', severity, package_id, semantic_model_id, 'Model contract is missing dbt_model or semantic_model_id.')) %}
    {{ return(issues) }}
  {% endif %}

  {% if resource_type != 'model' and (expected_version is not none or expected_latest is not none or expected_access is not none or (require_model_version | as_bool) or (expected_contract_enforced | as_bool)) %}
    {% do issues.append(semantic_rails_issue('INVALID_MODEL_CONTRACT', severity, package_id, semantic_model_id, 'dbt model governance fields only apply to model resources. Remove dbt_version, latest_version, access, require_model_version, and contract_enforced from ' ~ resource_type ~ ' contracts.')) %}
    {{ return(issues) }}
  {% endif %}

  {% set candidates = [] %}
  {% if resource_type == 'source' %}
    {% set dbt_source_name = model_contract.get('dbt_source_name', model_contract.get('dbt_source')) %}
    {% set dbt_source_table = model_contract.get('dbt_source_table', dbt_model) %}
    {% if not dbt_source_name or not dbt_source_table %}
      {% do issues.append(semantic_rails_issue('INVALID_MODEL_CONTRACT', severity, package_id, semantic_model_id, 'Source contracts require dbt_source_name and dbt_source_table (or dbt_model as the table name).')) %}
      {{ return(issues) }}
    {% endif %}
    {% for source in graph.sources.values()
        | selectattr("source_name", "equalto", dbt_source_name)
        | selectattr("name", "equalto", dbt_source_table) %}
      {% if not dbt_package or dbt_package == '*' or source.get('package_name') == dbt_package %}
        {% do candidates.append(source) %}
      {% endif %}
    {% endfor %}
  {% else %}
    {% for node in graph.nodes.values()
        | selectattr("resource_type", "equalto", resource_type)
        | selectattr("name", "equalto", dbt_model) %}
      {% if not dbt_package or dbt_package == '*' or node.get('package_name') == dbt_package %}
        {% do candidates.append(node) %}
      {% endif %}
    {% endfor %}
  {% endif %}

  {% if candidates | length == 0 %}
    {% set not_found_code = 'DBT_MODEL_NOT_FOUND' if resource_type == 'model' else 'DBT_RESOURCE_NOT_FOUND' %}
    {% do issues.append(semantic_rails_issue(not_found_code, severity, package_id, semantic_model_id, 'Expected dbt ' ~ resource_type ~ ' ' ~ dbt_package ~ '.' ~ dbt_model ~ ' was not found in the dbt graph.')) %}
    {{ return(issues) }}
  {% endif %}

  {% set matches = candidates %}
  {% if expected_version is not none %}
    {% set version_matches = [] %}
    {% set found_versions = [] %}
    {% for node in candidates %}
      {% do found_versions.append(node.get('version')) %}
      {% if (node.get('version') | string) == (expected_version | string) %}
        {% do version_matches.append(node) %}
      {% endif %}
    {% endfor %}
    {% if version_matches | length == 0 %}
      {% do issues.append(semantic_rails_issue('DBT_MODEL_VERSION_MISMATCH', severity, package_id, semantic_model_id, 'Expected dbt model version ' ~ expected_version ~ ' for ' ~ dbt_model ~ ', found version(s): ' ~ (found_versions | join(', ')) ~ '.')) %}
      {{ return(issues) }}
    {% endif %}
    {% set matches = version_matches %}
  {% endif %}

  {% if matches | length > 1 %}
    {% do issues.append(semantic_rails_issue('DBT_MODEL_AMBIGUOUS', severity, package_id, semantic_model_id, 'Expected dbt model ' ~ dbt_model ~ ' matched multiple nodes. Pin dbt_package or dbt_version.')) %}
    {{ return(issues) }}
  {% endif %}

  {% set node = matches[0] %}
  {% if resource_type == 'model' and (require_model_version | as_bool) and node.get('version') is none %}
    {% do issues.append(semantic_rails_issue('DBT_MODEL_VERSION_MISSING', severity, package_id, semantic_model_id, 'Expected versioned dbt model, but ' ~ dbt_model ~ ' has no dbt model version.')) %}
  {% endif %}

  {% if resource_type == 'model' and expected_version is not none and (node.get('version') | string) != (expected_version | string) %}
    {% do issues.append(semantic_rails_issue('DBT_MODEL_VERSION_MISMATCH', severity, package_id, semantic_model_id, 'Expected dbt model version ' ~ expected_version ~ ', found ' ~ node.get('version') ~ '.')) %}
  {% endif %}

  {% if resource_type == 'model' and expected_latest is not none and (node.get('latest_version') | string) != (expected_latest | string) %}
    {% do issues.append(semantic_rails_issue('DBT_LATEST_VERSION_MISMATCH', severity, package_id, semantic_model_id, 'Expected latest_version ' ~ expected_latest ~ ', found ' ~ node.get('latest_version') ~ '.')) %}
  {% endif %}

  {% if resource_type == 'model' and expected_access and node.get('access') != expected_access %}
    {% do issues.append(semantic_rails_issue('DBT_MODEL_ACCESS_MISMATCH', severity, package_id, semantic_model_id, 'Expected access ' ~ expected_access ~ ', found ' ~ node.get('access') ~ '.')) %}
  {% endif %}

  {% set relation_fields = {
    'alias': model_contract.get('dbt_alias', model_contract.get('alias')),
    'schema': model_contract.get('dbt_schema', model_contract.get('schema')),
    'database': model_contract.get('dbt_database', model_contract.get('database')),
    'identifier': model_contract.get('dbt_identifier', model_contract.get('identifier')),
    'relation_name': model_contract.get('dbt_relation_name', model_contract.get('relation_name'))
  } %}
  {% for field_name, expected_relation_value in relation_fields.items() %}
    {% set actual_relation_value = node.get(field_name) %}
    {% if field_name == 'identifier' and actual_relation_value is none %}
      {% set actual_relation_value = node.get('alias') %}
    {% endif %}
    {% if field_name == 'identifier' and actual_relation_value is none %}
      {% set actual_relation_value = node.get('name') %}
    {% endif %}
    {% if expected_relation_value is not none and (actual_relation_value | string) != (expected_relation_value | string) %}
      {% do issues.append(semantic_rails_issue('DBT_RELATION_MISMATCH', severity, package_id, semantic_model_id, 'Expected dbt ' ~ resource_type ~ ' ' ~ field_name ~ ' ' ~ expected_relation_value ~ ', found ' ~ actual_relation_value ~ '.')) %}
    {% endif %}
  {% endfor %}

  {% set config = node.get('config', {}) %}
  {% set contract_config = config.get('contract', {}) if config is mapping else {} %}
  {% set contract_enforced = contract_config.get('enforced', false) if contract_config is mapping else false %}
  {% if resource_type == 'model' and expected_contract_enforced | as_bool and not (contract_enforced | as_bool) %}
    {% do issues.append(semantic_rails_issue('DBT_CONTRACT_NOT_ENFORCED', severity, package_id, semantic_model_id, 'Expected dbt model contract.enforced: true for ' ~ dbt_model ~ '.')) %}
  {% endif %}

  {% set actual_columns = semantic_rails_columns_by_name(node.get('columns', {})) %}
  {% set expected_columns = semantic_rails_expected_columns(model_contract.get('columns', [])) %}
  {% for expected_column in expected_columns %}
    {% set column_name = expected_column.get('name') %}
    {% if not column_name %}
      {% do issues.append(semantic_rails_issue('INVALID_MODEL_CONTRACT', severity, package_id, semantic_model_id, 'Every expected column entry must include name.')) %}
    {% else %}
      {% set key = column_name | lower %}
      {% if key not in actual_columns %}
        {% set reason = expected_column.get('required_by', []) | join(', ') %}
        {% set detail = 'Missing dbt column ' ~ column_name ~ ' required by Semantic Rails model ' ~ semantic_model_id %}
        {% if reason %}
          {% set detail = detail ~ ' (' ~ reason ~ ')' %}
        {% endif %}
        {% do issues.append(semantic_rails_issue('DBT_COLUMN_MISSING', severity, package_id, semantic_model_id, detail ~ '.')) %}
      {% elif type_check != 'ignore' and expected_column.get('data_type') %}
        {% set actual_type = actual_columns[key].get('data_type', '') %}
        {% set expected_type = expected_column.get('data_type') %}
        {% if not semantic_rails_types_match(expected_type, actual_type, type_check) %}
          {% do issues.append(semantic_rails_issue('DBT_COLUMN_TYPE_MISMATCH', severity, package_id, semantic_model_id, 'Column ' ~ column_name ~ ' expected type ' ~ expected_type ~ ', found ' ~ actual_type ~ '.')) %}
        {% endif %}
      {% endif %}
    {% endif %}
  {% endfor %}

  {% if not (allow_extra_columns | as_bool) %}
    {% set expected_names = [] %}
    {% for expected_column in expected_columns %}
      {% do expected_names.append(expected_column.get('name') | lower) %}
    {% endfor %}
    {% for actual_name in actual_columns.keys() %}
      {% if actual_name not in expected_names %}
        {% do issues.append(semantic_rails_issue('DBT_COLUMN_EXTRA', severity, package_id, semantic_model_id, 'dbt column ' ~ actual_name ~ ' is not listed in the Semantic Rails contract and allow_extra_columns is false.')) %}
      {% endif %}
    {% endfor %}
  {% endif %}

  {{ return(issues) }}
{% endmacro %}


{% macro semantic_rails_contract_entries(package_contract) %}
  {% set out = [] %}
  {% set resources = semantic_rails_model_contracts(package_contract.get('resources', [])) %}
  {% for row in resources %}
    {% do out.append(row) %}
  {% endfor %}
  {% set models = semantic_rails_model_contracts(package_contract.get('models', [])) %}
  {% for row in models %}
    {% if not row.get('dbt_resource_type') and not row.get('resource_type') %}
      {% do row.update({'dbt_resource_type': 'model'}) %}
    {% endif %}
    {% do out.append(row) %}
  {% endfor %}
  {{ return(out) }}
{% endmacro %}


{% macro semantic_rails_contract_packages(spec) %}
  {% if spec.get('packages') is sequence %}
    {{ return(spec.get('packages')) }}
  {% endif %}
  {% if spec.get('models') %}
    {{ return([spec]) }}
  {% endif %}
  {% if spec.get('resources') %}
    {{ return([spec]) }}
  {% endif %}
  {{ return([]) }}
{% endmacro %}


{% macro semantic_rails_model_contracts(models) %}
  {% set out = [] %}
  {% if models is mapping %}
    {% for semantic_model_id, payload in models.items() %}
      {% set row = dict(payload or {}) %}
      {% if not row.get('semantic_model_id') %}
        {% do row.update({'semantic_model_id': semantic_model_id}) %}
      {% endif %}
      {% do out.append(row) %}
    {% endfor %}
  {% elif models is sequence %}
    {% for row in models %}
      {% if row is mapping %}
        {% do out.append(row) %}
      {% endif %}
    {% endfor %}
  {% endif %}
  {{ return(out) }}
{% endmacro %}


{% macro semantic_rails_columns_by_name(columns) %}
  {% set out = {} %}
  {% if columns is mapping %}
    {% for name, column in columns.items() %}
      {% set row = dict(column or {}) %}
      {% if not row.get('name') %}
        {% do row.update({'name': name}) %}
      {% endif %}
      {% do out.update({(name | lower): row}) %}
    {% endfor %}
  {% elif columns is sequence %}
    {% for column in columns %}
      {% if column is mapping and column.get('name') %}
        {% do out.update({(column.get('name') | lower): column}) %}
      {% endif %}
    {% endfor %}
  {% endif %}
  {{ return(out) }}
{% endmacro %}


{% macro semantic_rails_expected_columns(columns) %}
  {% set out = [] %}
  {% if columns is mapping %}
    {% for name, payload in columns.items() %}
      {% set row = dict(payload or {}) %}
      {% if not row.get('name') %}
        {% do row.update({'name': name}) %}
      {% endif %}
      {% do out.append(row) %}
    {% endfor %}
  {% elif columns is sequence %}
    {% for column in columns %}
      {% if column is string %}
        {% do out.append({'name': column}) %}
      {% elif column is mapping and column.get('name') %}
        {% do out.append(column) %}
      {% endif %}
    {% endfor %}
  {% endif %}
  {{ return(out) }}
{% endmacro %}


{% macro semantic_rails_types_match(expected_type, actual_type, mode='compatible') %}
  {% set expected = (expected_type or '') | lower | trim %}
  {% set actual = (actual_type or '') | lower | trim %}
  {% if mode == 'exact' %}
    {{ return(expected == actual) }}
  {% endif %}
  {% set aliases = {
    'string': ['string', 'varchar', 'text', 'character varying'],
    'varchar': ['string', 'varchar', 'text', 'character varying'],
    'integer': ['int', 'integer', 'bigint', 'number', 'numeric'],
    'bigint': ['int', 'integer', 'bigint', 'number', 'numeric'],
    'numeric': ['numeric', 'number', 'decimal', 'double', 'float', 'real'],
    'double': ['numeric', 'number', 'decimal', 'double', 'float', 'real'],
    'boolean': ['boolean', 'bool'],
    'timestamp': ['timestamp', 'timestamp_ntz', 'timestamp_tz', 'datetime'],
    'date': ['date']
  } %}
  {% set expected_group = aliases.get(expected, [expected]) %}
  {{ return(actual in expected_group) }}
{% endmacro %}


{% macro semantic_rails_issue(code, severity, package_id, model_id, message) %}
  {{ return({
    "code": code,
    "severity": severity,
    "package_id": package_id,
    "model": model_id,
    "message": message
  }) }}
{% endmacro %}


{% macro semantic_rails_format_contract_issue(issue) %}
  {% set prefix = issue.get('severity', 'error') | upper ~ ' ' ~ issue.get('code') %}
  {% set scope = issue.get('package_id', '') %}
  {% if issue.get('model') %}
    {% set scope = scope ~ '.' ~ issue.get('model') %}
  {% endif %}
  {{ return(prefix ~ ' [' ~ scope ~ '] ' ~ issue.get('message')) }}
{% endmacro %}


{% macro semantic_rails_contract_summary(spec) %}
  {% set packages = semantic_rails_contract_packages(spec) if spec is mapping else [] %}
  {% set resource_count = namespace(value=0) %}
  {% for package_contract in packages %}
    {% set resource_count.value = resource_count.value + (semantic_rails_contract_entries(package_contract) | length) %}
  {% endfor %}
  {{ return({"package_count": packages | length, "resource_count": resource_count.value, "model_count": resource_count.value}) }}
{% endmacro %}
