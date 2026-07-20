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
    {{ return({}) }}
  {% endif %}

  {% set spec = contract if contract is not none else var(var_name, {}) %}
  {% set report = semantic_rails_validation_report(spec) %}
  {% do print(tojson(report)) %}
  {{ return(report) }}
{% endmacro %}


{% macro semantic_rails_collect_contract_issues(spec) %}
  {% set normalized = semantic_rails_normalize_contract(spec) %}
  {% set issues = normalized.get('issues', []) %}
  {% set packages = normalized.get('packages', []) %}

  {% for package_contract in packages %}
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
  {% endfor %}

  {{ return(issues) }}
{% endmacro %}


{% macro semantic_rails_normalize_contract(spec) %}
  {% set issues = [] %}
  {% if spec is not mapping or (spec | length) == 0 %}
    {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'vars.semantic_rails_contracts must be a non-empty mapping.')) %}
    {{ return({"contract_format_version": none, "binding_kind": none, "binding_version": none, "legacy": false, "packages": [], "issues": issues}) }}
  {% endif %}

  {% set composed = 'contract_format_version' in spec or 'semantic' in spec or 'binding' in spec %}
  {% if composed %}
    {{ return(semantic_rails_normalize_composed_v1(spec)) }}
  {% endif %}

  {% set legacy_version = spec.get('contract_version') %}
  {% if legacy_version is not none and (legacy_version | string) != '1' %}
    {% do issues.append(semantic_rails_issue('UNSUPPORTED_LEGACY_CONTRACT_VERSION', 'error', '', '', 'Legacy contract_version ' ~ legacy_version ~ ' is unsupported; supported legacy version is 1.')) %}
  {% endif %}
  {% do issues.append(semantic_rails_issue('LEGACY_CONTRACT_FORMAT_DEPRECATED', 'warn', '', '', 'The legacy combined payload is deprecated. Regenerate this contract in composed contract format v1.')) %}
  {% set packages = semantic_rails_legacy_contract_packages(spec) %}
  {% if packages | length == 0 %}
    {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'No Semantic Rails packages were declared. Use composed contract format v1 or a legacy packages/models/resources payload.')) %}
  {% endif %}
  {{ return({"contract_format_version": 0, "binding_kind": none, "binding_version": none, "legacy": true, "packages": packages, "issues": issues}) }}
{% endmacro %}


{% macro semantic_rails_normalize_composed_v1(spec) %}
  {% set issues = [] %}
  {% set packages = [] %}
  {% set allowed_top_level = ['contract_format_version', 'semantic', 'binding'] %}
  {% for key in spec.keys() %}
    {% if key not in allowed_top_level %}
      {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'Unsupported top-level field ' ~ key ~ ' in composed contract format v1.')) %}
    {% endif %}
  {% endfor %}

  {% set contract_format_version = spec.get('contract_format_version') %}
  {% if contract_format_version is none %}
    {% do issues.append(semantic_rails_issue('CONTRACT_FORMAT_VERSION_REQUIRED', 'error', '', '', 'contract_format_version is required for a composed contract.')) %}
  {% elif contract_format_version is not integer or contract_format_version != 1 %}
    {% do issues.append(semantic_rails_issue('UNSUPPORTED_CONTRACT_FORMAT_VERSION', 'error', '', '', 'contract_format_version ' ~ contract_format_version ~ ' is unsupported; supported version is 1.')) %}
  {% endif %}

  {% set semantic = spec.get('semantic') %}
  {% if semantic is not mapping %}
    {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'semantic must be a mapping.')) %}
  {% endif %}
  {% set binding = spec.get('binding') %}
  {% if binding is not mapping %}
    {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'binding must be a mapping.')) %}
  {% endif %}

  {% set binding_kind = binding.get('kind') if binding is mapping else none %}
  {% if binding_kind != 'dbt' %}
    {% do issues.append(semantic_rails_issue('BINDING_KIND_MISMATCH', 'error', '', '', 'binding.kind must be dbt, found ' ~ binding_kind ~ '.')) %}
  {% endif %}
  {% set binding_version = binding.get('binding_version') if binding is mapping else none %}
  {% if binding_version is none %}
    {% do issues.append(semantic_rails_issue('BINDING_VERSION_REQUIRED', 'error', '', '', 'binding.binding_version is required.')) %}
  {% elif binding_version is not integer or binding_version != 1 %}
    {% do issues.append(semantic_rails_issue('UNSUPPORTED_BINDING_VERSION', 'error', '', '', 'dbt binding_version ' ~ binding_version ~ ' is unsupported; supported version is 1.')) %}
  {% endif %}

  {% if contract_format_version is not integer or contract_format_version != 1 or semantic is not mapping or binding is not mapping or binding_kind != 'dbt' or binding_version is not integer or binding_version != 1 %}
    {{ return({"contract_format_version": contract_format_version, "binding_kind": binding_kind if binding_kind is string else none, "binding_version": binding_version, "legacy": false, "packages": packages, "issues": issues}) }}
  {% endif %}

  {% set allowed_semantic_keys = ['producer', 'packages'] %}
  {% for key in semantic.keys() %}
    {% if key not in allowed_semantic_keys %}
      {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'Unsupported semantic field ' ~ key ~ '.')) %}
    {% endif %}
  {% endfor %}
  {% set producer = semantic.get('producer') %}
  {% if producer is not mapping %}
    {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'semantic.producer must be a mapping with name and version.')) %}
  {% else %}
    {% for key in producer.keys() %}
      {% if key not in ['name', 'version'] %}
        {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'Unsupported semantic.producer field ' ~ key ~ '.')) %}
      {% endif %}
    {% endfor %}
    {% set producer_name = producer.get('name') %}
    {% set producer_version = producer.get('version') %}
    {% if producer_name != 'semantic-rails' %}
      {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'semantic.producer.name must be semantic-rails.')) %}
    {% endif %}
    {% if producer_version is not string or not producer_version %}
      {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'semantic.producer.version must be a non-empty string.')) %}
    {% endif %}
  {% endif %}

  {% set allowed_binding_keys = ['kind', 'binding_version', 'packages'] %}
  {% for key in binding.keys() %}
    {% if key not in allowed_binding_keys %}
      {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'Unsupported binding field ' ~ key ~ '.')) %}
    {% endif %}
  {% endfor %}

  {% set semantic_packages = semantic.get('packages') %}
  {% if semantic_packages is not sequence or semantic_packages is string or semantic_packages is mapping or (semantic_packages | length) == 0 %}
    {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'semantic.packages must be a non-empty list.')) %}
    {% set semantic_packages = [] %}
  {% endif %}
  {% set binding_packages = binding.get('packages') %}
  {% if binding_packages is not sequence or binding_packages is string or binding_packages is mapping or (binding_packages | length) == 0 %}
    {% do issues.append(semantic_rails_issue('INVALID_CONTRACT', 'error', '', '', 'binding.packages must be a non-empty list.')) %}
    {% set binding_packages = [] %}
  {% endif %}

  {% set semantic_by_id = {} %}
  {% for semantic_package in semantic_packages %}
    {% if semantic_package is not mapping %}
      {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_PACKAGE', 'error', '', '', 'Every semantic.packages entry must be a mapping.')) %}
    {% else %}
      {% set package_id = semantic_package.get('package_id') %}
      {% set allowed_package_keys = ['package_id', 'namespace', 'package_schema_version', 'semantic_hash', 'resources'] %}
      {% set state = namespace(valid=true) %}
      {% for key in semantic_package.keys() %}
        {% if key not in allowed_package_keys %}
          {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_PACKAGE', 'error', package_id or '', '', 'Unsupported semantic package field ' ~ key ~ '.')) %}
          {% set state.valid = false %}
        {% endif %}
      {% endfor %}
      {% if package_id is not string or not package_id %}
        {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_PACKAGE', 'error', '', '', 'semantic package_id must be a non-empty string.')) %}
        {% set state.valid = false %}
      {% elif package_id in semantic_by_id %}
        {% do issues.append(semantic_rails_issue('DUPLICATE_SEMANTIC_PACKAGE', 'error', package_id, '', 'semantic package_id is duplicated.')) %}
        {% set state.valid = false %}
      {% endif %}
      {% set semantic_namespace = semantic_package.get('namespace') %}
      {% if semantic_namespace is not none and semantic_namespace is not string %}
        {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_PACKAGE', 'error', package_id or '', '', 'namespace must be a string when provided.')) %}
        {% set state.valid = false %}
      {% endif %}
      {% set package_schema_version = semantic_package.get('package_schema_version') %}
      {% if package_schema_version is none %}
        {% do issues.append(semantic_rails_issue('PACKAGE_SCHEMA_VERSION_REQUIRED', 'error', package_id or '', '', 'package_schema_version is required.')) %}
        {% set state.valid = false %}
      {% elif package_schema_version is not integer or package_schema_version != 1 %}
        {% do issues.append(semantic_rails_issue('UNSUPPORTED_PACKAGE_SCHEMA_VERSION', 'error', package_id or '', '', 'package_schema_version ' ~ package_schema_version ~ ' is unsupported; supported version is 1.')) %}
        {% set state.valid = false %}
      {% endif %}
      {% set semantic_hash = semantic_package.get('semantic_hash') %}
      {% set hash_invalid = namespace(value=false) %}
      {% if semantic_hash is not string or (semantic_hash | length) != 71 or not semantic_hash.startswith('sha256:') %}
        {% set hash_invalid.value = true %}
      {% else %}
        {% for character in semantic_hash[7:] %}
          {% if character not in '0123456789abcdef' %}
            {% set hash_invalid.value = true %}
          {% endif %}
        {% endfor %}
      {% endif %}
      {% if hash_invalid.value %}
        {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_PACKAGE', 'error', package_id or '', '', 'semantic_hash must be sha256: followed by 64 lowercase hexadecimal characters.')) %}
        {% set state.valid = false %}
      {% endif %}
      {% set resources = semantic_package.get('resources') %}
      {% if resources is not sequence or resources is string or resources is mapping or (resources | length) == 0 %}
        {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_PACKAGE', 'error', package_id or '', '', 'semantic package resources must be a non-empty list.')) %}
        {% set state.valid = false %}
      {% endif %}
      {% if state.valid %}
        {% do semantic_by_id.update({package_id: semantic_package}) %}
      {% endif %}
    {% endif %}
  {% endfor %}

  {% set binding_by_id = {} %}
  {% for binding_package in binding_packages %}
    {% if binding_package is not mapping %}
      {% do issues.append(semantic_rails_issue('INVALID_BINDING_PACKAGE', 'error', '', '', 'Every binding.packages entry must be a mapping.')) %}
    {% else %}
      {% set package_id = binding_package.get('package_id') %}
      {% set allowed_package_keys = ['package_id', 'policy', 'resources'] %}
      {% set state = namespace(valid=true) %}
      {% for key in binding_package.keys() %}
        {% if key not in allowed_package_keys %}
          {% do issues.append(semantic_rails_issue('INVALID_BINDING_PACKAGE', 'error', package_id or '', '', 'Unsupported dbt binding package field ' ~ key ~ '.')) %}
          {% set state.valid = false %}
        {% endif %}
      {% endfor %}
      {% if package_id is not string or not package_id %}
        {% do issues.append(semantic_rails_issue('INVALID_BINDING_PACKAGE', 'error', '', '', 'dbt binding package_id must be a non-empty string.')) %}
        {% set state.valid = false %}
      {% elif package_id in binding_by_id %}
        {% do issues.append(semantic_rails_issue('DUPLICATE_BINDING_PACKAGE', 'error', package_id, '', 'dbt binding package_id is duplicated.')) %}
        {% set state.valid = false %}
      {% endif %}
      {% if 'policy' not in binding_package %}
        {% do issues.append(semantic_rails_issue('INVALID_BINDING_PACKAGE', 'error', package_id or '', '', 'dbt binding package policy is required.')) %}
        {% set state.valid = false %}
      {% endif %}
      {% set policy_issues = semantic_rails_validate_dbt_policy(binding_package.get('policy', {}), package_id or '') %}
      {% for issue in policy_issues %}
        {% do issues.append(issue) %}
        {% set state.valid = false %}
      {% endfor %}
      {% set resources = binding_package.get('resources') %}
      {% if resources is not sequence or resources is string or resources is mapping or (resources | length) == 0 %}
        {% do issues.append(semantic_rails_issue('INVALID_BINDING_PACKAGE', 'error', package_id or '', '', 'dbt binding package resources must be a non-empty list.')) %}
        {% set state.valid = false %}
      {% endif %}
      {% if state.valid %}
        {% do binding_by_id.update({package_id: binding_package}) %}
      {% endif %}
    {% endif %}
  {% endfor %}

  {% for package_id, binding_package in binding_by_id.items() %}
    {% if package_id not in semantic_by_id %}
      {% do issues.append(semantic_rails_issue('SEMANTIC_PACKAGE_NOT_FOUND', 'error', package_id, '', 'dbt binding package has no matching semantic package.')) %}
    {% endif %}
  {% endfor %}

  {% for package_id, semantic_package in semantic_by_id.items() %}
    {% if package_id not in binding_by_id %}
      {% do issues.append(semantic_rails_issue('DBT_BINDING_PACKAGE_NOT_FOUND', 'error', package_id, '', 'semantic package has no matching dbt binding package.')) %}
    {% else %}
      {% set binding_package = binding_by_id[package_id] %}
      {% set semantic_resources = {} %}
      {% set binding_resources = {} %}

      {% for resource in semantic_package.get('resources', []) %}
        {% set resource_issues = semantic_rails_validate_semantic_resource(resource, package_id) %}
        {% for issue in resource_issues %}
          {% do issues.append(issue) %}
        {% endfor %}
        {% if resource is mapping and resource.get('semantic_model_id') is string and resource.get('semantic_model_id') %}
          {% set resource_id = resource.get('semantic_model_id') %}
          {% if resource_id in semantic_resources %}
            {% do issues.append(semantic_rails_issue('DUPLICATE_SEMANTIC_RESOURCE', 'error', package_id, resource_id, 'semantic_model_id is duplicated in semantic resources.')) %}
          {% elif resource_issues | length == 0 %}
            {% do semantic_resources.update({resource_id: resource}) %}
          {% endif %}
        {% endif %}
      {% endfor %}

      {% for resource in binding_package.get('resources', []) %}
        {% set resource_issues = semantic_rails_validate_dbt_binding_resource(resource, package_id) %}
        {% for issue in resource_issues %}
          {% do issues.append(issue) %}
        {% endfor %}
        {% if resource is mapping and resource.get('semantic_model_id') is string and resource.get('semantic_model_id') %}
          {% set resource_id = resource.get('semantic_model_id') %}
          {% if resource_id in binding_resources %}
            {% do issues.append(semantic_rails_issue('DUPLICATE_BINDING_RESOURCE', 'error', package_id, resource_id, 'semantic_model_id is duplicated in dbt binding resources.')) %}
          {% elif resource_issues | length == 0 %}
            {% do binding_resources.update({resource_id: resource}) %}
          {% endif %}
        {% endif %}
      {% endfor %}

      {% for resource_id in binding_resources.keys() %}
        {% if resource_id not in semantic_resources %}
          {% do issues.append(semantic_rails_issue('SEMANTIC_RESOURCE_NOT_FOUND', 'error', package_id, resource_id, 'dbt binding resource has no matching semantic resource.')) %}
        {% endif %}
      {% endfor %}

      {% set merged_resources = [] %}
      {% for resource_id, semantic_resource in semantic_resources.items() %}
        {% if resource_id not in binding_resources %}
          {% do issues.append(semantic_rails_issue('DBT_BINDING_RESOURCE_NOT_FOUND', 'error', package_id, resource_id, 'semantic resource has no matching dbt binding resource.')) %}
        {% else %}
          {% set merged = dict(binding_resources[resource_id]) %}
          {% do merged.update({'columns': semantic_resource.get('columns', [])}) %}
          {% if semantic_resource.get('relation') is not none %}
            {% do merged.update({'semantic_relation': semantic_resource.get('relation')}) %}
          {% endif %}
          {% do merged_resources.append(merged) %}
        {% endif %}
      {% endfor %}

      {% if merged_resources | length > 0 %}
        {% do packages.append({
          'package_id': package_id,
          'namespace': semantic_package.get('namespace'),
          'package_schema_version': semantic_package.get('package_schema_version'),
          'semantic_hash': semantic_package.get('semantic_hash'),
          'policy': binding_package.get('policy', {}),
          'resources': merged_resources
        }) %}
      {% endif %}
    {% endif %}
  {% endfor %}

  {{ return({"contract_format_version": 1, "binding_kind": "dbt", "binding_version": 1, "legacy": false, "packages": packages, "issues": issues}) }}
{% endmacro %}


{% macro semantic_rails_validate_dbt_policy(policy, package_id) %}
  {% set issues = [] %}
  {% if policy is not mapping %}
    {% do issues.append(semantic_rails_issue('INVALID_BINDING_PACKAGE', 'error', package_id, '', 'dbt binding policy must be a mapping.')) %}
    {{ return(issues) }}
  {% endif %}
  {% set allowed = ['severity', 'type_check', 'allow_extra_columns', 'require_model_contract', 'require_model_version'] %}
  {% for key in policy.keys() %}
    {% if key not in allowed %}
      {% do issues.append(semantic_rails_issue('INVALID_BINDING_PACKAGE', 'error', package_id, '', 'Unsupported dbt policy field ' ~ key ~ '.')) %}
    {% endif %}
  {% endfor %}
  {% if policy.get('severity', 'error') not in ['error', 'warn'] %}
    {% do issues.append(semantic_rails_issue('INVALID_BINDING_PACKAGE', 'error', package_id, '', 'policy.severity must be error or warn.')) %}
  {% endif %}
  {% if policy.get('type_check', 'ignore') not in ['ignore', 'compatible', 'exact'] %}
    {% do issues.append(semantic_rails_issue('INVALID_BINDING_PACKAGE', 'error', package_id, '', 'policy.type_check must be ignore, compatible, or exact.')) %}
  {% endif %}
  {% for key in ['allow_extra_columns', 'require_model_contract', 'require_model_version'] %}
    {% if policy.get(key) is not none and policy.get(key) is not boolean %}
      {% do issues.append(semantic_rails_issue('INVALID_BINDING_PACKAGE', 'error', package_id, '', 'policy.' ~ key ~ ' must be a boolean.')) %}
    {% endif %}
  {% endfor %}
  {{ return(issues) }}
{% endmacro %}


{% macro semantic_rails_validate_semantic_resource(resource, package_id) %}
  {% set issues = [] %}
  {% if resource is not mapping %}
    {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_RESOURCE', 'error', package_id, '', 'Every semantic resource must be a mapping.')) %}
    {{ return(issues) }}
  {% endif %}
  {% set resource_id = resource.get('semantic_model_id') %}
  {% set allowed = ['semantic_model_id', 'relation', 'columns'] %}
  {% for key in resource.keys() %}
    {% if key not in allowed %}
      {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_RESOURCE', 'error', package_id, resource_id or '', 'Unsupported semantic resource field ' ~ key ~ '.')) %}
    {% endif %}
  {% endfor %}
  {% if resource_id is not string or not resource_id %}
    {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_RESOURCE', 'error', package_id, '', 'semantic_model_id must be a non-empty string.')) %}
  {% endif %}
  {% if resource.get('relation') is not none and resource.get('relation') is not string %}
    {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_RESOURCE', 'error', package_id, resource_id or '', 'relation must be a string when provided.')) %}
  {% endif %}
  {% set column_issues = semantic_rails_validate_semantic_columns(resource.get('columns'), package_id, resource_id or '') %}
  {% for issue in column_issues %}
    {% do issues.append(issue) %}
  {% endfor %}
  {{ return(issues) }}
{% endmacro %}


{% macro semantic_rails_validate_semantic_columns(columns, package_id, resource_id) %}
  {% set issues = [] %}
  {% if columns is not sequence or columns is string or columns is mapping %}
    {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_COLUMNS', 'error', package_id, resource_id, 'semantic resource columns must be a list.')) %}
    {{ return(issues) }}
  {% endif %}
  {% set names = [] %}
  {% for column in columns %}
    {% if column is not mapping %}
      {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_COLUMN', 'error', package_id, resource_id, 'Every semantic column must be a mapping.')) %}
    {% else %}
      {% set name = column.get('name') %}
      {% set allowed = ['name', 'data_type', 'required_by'] %}
      {% for key in column.keys() %}
        {% if key not in allowed %}
          {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_COLUMN', 'error', package_id, resource_id, 'Unsupported semantic column field ' ~ key ~ '.')) %}
        {% endif %}
      {% endfor %}
      {% if name is not string or not name %}
        {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_COLUMN', 'error', package_id, resource_id, 'Every semantic column must include a non-empty name.')) %}
      {% elif (name | lower) in names %}
        {% do issues.append(semantic_rails_issue('DUPLICATE_SEMANTIC_COLUMN', 'error', package_id, resource_id, 'Semantic column ' ~ name ~ ' is duplicated.')) %}
      {% else %}
        {% do names.append(name | lower) %}
      {% endif %}
      {% if column.get('data_type') is not none and (column.get('data_type') is not string or not column.get('data_type')) %}
        {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_COLUMN', 'error', package_id, resource_id, 'column.data_type must be a non-empty string when provided.')) %}
      {% endif %}
      {% set required_by = column.get('required_by') %}
      {% if required_by is not sequence or required_by is string or required_by is mapping %}
        {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_COLUMN', 'error', package_id, resource_id, 'column.required_by must be a list of strings.')) %}
      {% else %}
        {% set seen_reasons = [] %}
        {% for reason in required_by %}
          {% if reason is not string or not reason %}
            {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_COLUMN', 'error', package_id, resource_id, 'Every column.required_by entry must be a non-empty string.')) %}
          {% elif reason in seen_reasons %}
            {% do issues.append(semantic_rails_issue('INVALID_SEMANTIC_COLUMN', 'error', package_id, resource_id, 'column.required_by entries must be unique.')) %}
          {% else %}
            {% do seen_reasons.append(reason) %}
          {% endif %}
        {% endfor %}
      {% endif %}
    {% endif %}
  {% endfor %}
  {{ return(issues) }}
{% endmacro %}


{% macro semantic_rails_validate_dbt_binding_resource(resource, package_id) %}
  {% set issues = [] %}
  {% if resource is not mapping %}
    {% do issues.append(semantic_rails_issue('INVALID_BINDING_RESOURCE', 'error', package_id, '', 'Every dbt binding resource must be a mapping.')) %}
    {{ return(issues) }}
  {% endif %}
  {% set resource_id = resource.get('semantic_model_id') %}
  {% set allowed = [
    'semantic_model_id', 'dbt_resource_type', 'dbt_model', 'dbt_source_name',
    'dbt_source_table', 'dbt_package', 'dbt_version', 'latest_version', 'access',
    'contract_enforced', 'allow_extra_columns', 'require_model_contract',
    'require_model_version', 'type_check', 'severity', 'dbt_alias', 'dbt_schema',
    'dbt_database', 'dbt_identifier', 'dbt_relation_name'
  ] %}
  {% for key in resource.keys() %}
    {% if key not in allowed %}
      {% do issues.append(semantic_rails_issue('INVALID_BINDING_RESOURCE', 'error', package_id, resource_id or '', 'Unsupported dbt binding resource field ' ~ key ~ '.')) %}
    {% endif %}
  {% endfor %}
  {% if resource_id is not string or not resource_id %}
    {% do issues.append(semantic_rails_issue('INVALID_BINDING_RESOURCE', 'error', package_id, '', 'dbt binding semantic_model_id must be a non-empty string.')) %}
  {% endif %}
  {% if resource.get('severity') is not none and resource.get('severity') not in ['error', 'warn'] %}
    {% do issues.append(semantic_rails_issue('INVALID_BINDING_RESOURCE', 'error', package_id, resource_id or '', 'resource severity must be error or warn.')) %}
  {% endif %}
  {% if resource.get('type_check') is not none and resource.get('type_check') not in ['ignore', 'compatible', 'exact'] %}
    {% do issues.append(semantic_rails_issue('INVALID_BINDING_RESOURCE', 'error', package_id, resource_id or '', 'resource type_check must be ignore, compatible, or exact.')) %}
  {% endif %}
  {% if resource.get('dbt_resource_type') is not none and resource.get('dbt_resource_type') not in ['model', 'source', 'seed', 'snapshot'] %}
    {% do issues.append(semantic_rails_issue('INVALID_BINDING_RESOURCE', 'error', package_id, resource_id or '', 'dbt_resource_type must be model, source, seed, or snapshot.')) %}
  {% endif %}
  {% if resource.get('access') is not none and resource.get('access') not in ['private', 'protected', 'public'] %}
    {% do issues.append(semantic_rails_issue('INVALID_BINDING_RESOURCE', 'error', package_id, resource_id or '', 'access must be private, protected, or public.')) %}
  {% endif %}
  {% for key in ['dbt_model', 'dbt_source_name', 'dbt_source_table', 'dbt_package', 'dbt_alias', 'dbt_schema', 'dbt_database', 'dbt_identifier', 'dbt_relation_name'] %}
    {% if resource.get(key) is not none and resource.get(key) is not string %}
      {% do issues.append(semantic_rails_issue('INVALID_BINDING_RESOURCE', 'error', package_id, resource_id or '', key ~ ' must be a string.')) %}
    {% endif %}
  {% endfor %}
  {% for key in ['contract_enforced', 'allow_extra_columns', 'require_model_contract', 'require_model_version'] %}
    {% if resource.get(key) is not none and resource.get(key) is not boolean %}
      {% do issues.append(semantic_rails_issue('INVALID_BINDING_RESOURCE', 'error', package_id, resource_id or '', key ~ ' must be a boolean.')) %}
    {% endif %}
  {% endfor %}
  {% for key in ['dbt_version', 'latest_version'] %}
    {% if resource.get(key) is not none and resource.get(key) is not integer and resource.get(key) is not string %}
      {% do issues.append(semantic_rails_issue('INVALID_BINDING_RESOURCE', 'error', package_id, resource_id or '', key ~ ' must be an integer or string.')) %}
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


{% macro semantic_rails_legacy_contract_packages(spec) %}
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
    "semantic_model_id": model_id,
    "message": message
  }) }}
{% endmacro %}


{% macro semantic_rails_format_contract_issue(issue) %}
  {% set prefix = issue.get('severity', 'error') | upper ~ ' ' ~ issue.get('code') %}
  {% set scope = issue.get('package_id', '') %}
  {% if issue.get('semantic_model_id') %}
    {% set scope = scope ~ '.' ~ issue.get('semantic_model_id') %}
  {% endif %}
  {{ return(prefix ~ ' [' ~ scope ~ '] ' ~ issue.get('message')) }}
{% endmacro %}


{% macro semantic_rails_contract_summary(spec) %}
  {% set normalized = semantic_rails_normalize_contract(spec) %}
  {% set packages = normalized.get('packages', []) %}
  {% set resource_count = namespace(value=0) %}
  {% for package_contract in packages %}
    {% set resource_count.value = resource_count.value + (semantic_rails_contract_entries(package_contract) | length) %}
  {% endfor %}
  {{ return({"package_count": packages | length, "resource_count": resource_count.value, "model_count": resource_count.value}) }}
{% endmacro %}


{% macro semantic_rails_validation_report(spec) %}
  {% set normalized = semantic_rails_normalize_contract(spec) %}
  {% set issues = semantic_rails_collect_contract_issues(spec) %}
  {% set has_errors = namespace(value=false) %}
  {% set error_count = namespace(value=0) %}
  {% set warning_count = namespace(value=0) %}
  {% set report_issues = [] %}
  {% for issue in issues %}
    {% if issue.get('severity', 'error') != 'warn' %}
      {% set has_errors.value = true %}
      {% set error_count.value = error_count.value + 1 %}
    {% else %}
      {% set warning_count.value = warning_count.value + 1 %}
    {% endif %}
    {% set report_issue = dict(issue) %}
    {% if report_issue.get('severity') == 'warn' %}
      {% do report_issue.update({'severity': 'warning'}) %}
    {% endif %}
    {% do report_issues.append(report_issue) %}
  {% endfor %}
  {% set contract_format_version = normalized.get('contract_format_version') %}
  {% if contract_format_version is not integer %}
    {% set contract_format_version = none %}
  {% endif %}
  {% set binding_version = normalized.get('binding_version') %}
  {% if binding_version is not integer %}
    {% set binding_version = none %}
  {% endif %}
  {% set contract_summary = semantic_rails_contract_summary(spec) %}
  {{ return({
    "report_format_version": 1,
    "ok": not has_errors.value,
    "validator": {
      "name": "dbt-semantic-rails-contracts",
      "version": "0.2.0"
    },
    "input": {
      "contract_format_version": contract_format_version,
      "binding_kind": normalized.get('binding_kind'),
      "binding_version": binding_version,
      "legacy": normalized.get('legacy', false)
    },
    "summary": {
      "package_count": contract_summary.get('package_count', 0),
      "resource_count": contract_summary.get('resource_count', 0),
      "error_count": error_count.value,
      "warning_count": warning_count.value
    },
    "issues": report_issues
  }) }}
{% endmacro %}
