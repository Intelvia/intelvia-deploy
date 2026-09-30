#!/usr/bin/env bash
set -Eeuo pipefail

: "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD is required}"
: "${MARIADB_DATABASE:?MARIADB_DATABASE is required}"
: "${MARIADB_APP_USER:?MARIADB_APP_USER is required}"
: "${MARIADB_APP_PASSWORD:?MARIADB_APP_PASSWORD is required}"
: "${MARIADB_MIGRATION_USER:?MARIADB_MIGRATION_USER is required}"
: "${MARIADB_MIGRATION_PASSWORD:?MARIADB_MIGRATION_PASSWORD is required}"
: "${MARIADB_REFRESH_USER:?MARIADB_REFRESH_USER is required}"
: "${MARIADB_REFRESH_PASSWORD:?MARIADB_REFRESH_PASSWORD is required}"

identifier_pattern='^[A-Za-z0-9_]+$'
for identifier in "$MARIADB_DATABASE" "$MARIADB_APP_USER" "$MARIADB_MIGRATION_USER" "$MARIADB_REFRESH_USER" "${MARIADB_LEGACY_USER:-}"; do
  [[ -z "$identifier" ]] && continue
  if [[ ! "$identifier" =~ $identifier_pattern ]]; then
    echo "MariaDB database and account names may contain only letters, numbers, and underscores" >&2
    exit 1
  fi
done

if [[ "$MARIADB_APP_USER" == "$MARIADB_MIGRATION_USER" ||
      "$MARIADB_APP_USER" == "$MARIADB_REFRESH_USER" ||
      "$MARIADB_MIGRATION_USER" == "$MARIADB_REFRESH_USER" ]]; then
  echo "Runtime, migration, and refresh MariaDB accounts must be different" >&2
  exit 1
fi

app_password_b64="$(printf '%s' "$MARIADB_APP_PASSWORD" | base64 | tr -d '\n')"
migration_password_b64="$(printf '%s' "$MARIADB_MIGRATION_PASSWORD" | base64 | tr -d '\n')"
refresh_password_b64="$(printf '%s' "$MARIADB_REFRESH_PASSWORD" | base64 | tr -d '\n')"

mariadb \
  --protocol=socket \
  --socket=/run/mysqld/mysqld.sock \
  -uroot \
  --password="$MARIADB_ROOT_PASSWORD" <<SQL
CREATE USER IF NOT EXISTS '${MARIADB_APP_USER}'@'%' REQUIRE SSL;
SET @app_password = FROM_BASE64('${app_password_b64}');
SET @app_alter = CONCAT(
  'ALTER USER ''${MARIADB_APP_USER}''@''%'' IDENTIFIED BY ',
  QUOTE(@app_password),
  ' REQUIRE SSL'
);
PREPARE app_alter_statement FROM @app_alter;
EXECUTE app_alter_statement;
DEALLOCATE PREPARE app_alter_statement;
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${MARIADB_APP_USER}'@'%';
GRANT SELECT ON \`${MARIADB_DATABASE}\`.* TO '${MARIADB_APP_USER}'@'%';

CREATE USER IF NOT EXISTS '${MARIADB_MIGRATION_USER}'@'%' REQUIRE SSL;
SET @migration_password = FROM_BASE64('${migration_password_b64}');
SET @migration_alter = CONCAT(
  'ALTER USER ''${MARIADB_MIGRATION_USER}''@''%'' IDENTIFIED BY ',
  QUOTE(@migration_password),
  ' REQUIRE SSL'
);
PREPARE migration_alter_statement FROM @migration_alter;
EXECUTE migration_alter_statement;
DEALLOCATE PREPARE migration_alter_statement;
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${MARIADB_MIGRATION_USER}'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES,
  CREATE TEMPORARY TABLES
  ON \`${MARIADB_DATABASE}\`.* TO '${MARIADB_MIGRATION_USER}'@'%';

CREATE USER IF NOT EXISTS '${MARIADB_REFRESH_USER}'@'%' REQUIRE SSL;
SET @refresh_password = FROM_BASE64('${refresh_password_b64}');
SET @refresh_alter = CONCAT(
  'ALTER USER ''${MARIADB_REFRESH_USER}''@''%'' IDENTIFIED BY ',
  QUOTE(@refresh_password),
  ' REQUIRE SSL'
);
PREPARE refresh_alter_statement FROM @refresh_alter;
EXECUTE refresh_alter_statement;
DEALLOCATE PREPARE refresh_alter_statement;
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${MARIADB_REFRESH_USER}'@'%';
GRANT SELECT, CREATE TEMPORARY TABLES ON \`${MARIADB_DATABASE}\`.* TO '${MARIADB_REFRESH_USER}'@'%';
GRANT INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES
  ON \`${MARIADB_DATABASE}\`.\`GuidelineAdherence\` TO '${MARIADB_REFRESH_USER}'@'%';
GRANT INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES
  ON \`${MARIADB_DATABASE}\`.\`GuidelineAdherenceFacts\` TO '${MARIADB_REFRESH_USER}'@'%';
GRANT INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES
  ON \`${MARIADB_DATABASE}\`.\`SurgeryCaseOutcomes\` TO '${MARIADB_REFRESH_USER}'@'%';
GRANT INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES
  ON \`${MARIADB_DATABASE}\`.\`VisitAttributes\` TO '${MARIADB_REFRESH_USER}'@'%';
GRANT INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES
  ON \`${MARIADB_DATABASE}\`.\`SurgeryCaseAttributes\` TO '${MARIADB_REFRESH_USER}'@'%';
GRANT INSERT, UPDATE, DELETE, CREATE
  ON \`${MARIADB_DATABASE}\`.\`DerivedArtifactRefresh\` TO '${MARIADB_REFRESH_USER}'@'%';
SQL

app_writable_tables=(
  api_state
  api_stateaccess
  DataExclusion
  IntelviaUserAccess
  IntelviaDepartmentAccess
  IntelviaSettings
  ProviderDepartmentMapping
  GuidelineAdherenceConfig
  auth_group
  auth_group_permissions
  auth_permission
  auth_user
  auth_user_groups
  auth_user_user_permissions
  django_admin_log
  django_session
  django_cas_ng_proxygrantingticket
  django_cas_ng_sessionticket
)
for table_name in "${app_writable_tables[@]}"; do
  table_exists="$(
    mariadb \
      --protocol=socket \
      --socket=/run/mysqld/mysqld.sock \
      -uroot \
      --password="$MARIADB_ROOT_PASSWORD" \
      --batch \
      --skip-column-names \
      -e "SELECT COUNT(*)
          FROM information_schema.TABLES
          WHERE TABLE_SCHEMA = '${MARIADB_DATABASE}'
            AND TABLE_NAME = '${table_name}'"
  )"
  if [[ "$table_exists" == "1" ]]; then
    mariadb \
      --protocol=socket \
      --socket=/run/mysqld/mysqld.sock \
      -uroot \
      --password="$MARIADB_ROOT_PASSWORD" \
      -e "GRANT INSERT, UPDATE, DELETE
          ON \`${MARIADB_DATABASE}\`.\`${table_name}\` TO '${MARIADB_APP_USER}'@'%'"
  fi
done

guideline_config_exists="$(
  mariadb \
    --protocol=socket \
    --socket=/run/mysqld/mysqld.sock \
    -uroot \
    --password="$MARIADB_ROOT_PASSWORD" \
    --batch \
    --skip-column-names \
    -e "SELECT COUNT(*)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${MARIADB_DATABASE}'
          AND TABLE_NAME = 'GuidelineAdherenceConfig'"
)"
if [[ "$guideline_config_exists" == "1" ]]; then
  mariadb \
    --protocol=socket \
    --socket=/run/mysqld/mysqld.sock \
    -uroot \
    --password="$MARIADB_ROOT_PASSWORD" \
    -e "GRANT UPDATE
        ON \`${MARIADB_DATABASE}\`.\`GuidelineAdherenceConfig\` TO '${MARIADB_REFRESH_USER}'@'%'"
fi

aria_encryption_marker=/var/lib/mysql/.intelvia-aria-encrypted-v1
if [[ ! -f "$aria_encryption_marker" ]]; then
  aria_tables="$(
    mariadb \
      --protocol=socket \
      --socket=/run/mysqld/mysqld.sock \
      -uroot \
      --password="$MARIADB_ROOT_PASSWORD" \
      --batch \
      --skip-column-names \
      -e "SELECT TABLE_SCHEMA, TABLE_NAME
          FROM information_schema.TABLES
          WHERE ENGINE = 'Aria'
            AND ROW_FORMAT = 'Page'
            AND TABLE_SCHEMA IN ('mysql', '${MARIADB_DATABASE}')
          ORDER BY TABLE_SCHEMA, TABLE_NAME"
  )"
  while IFS=$'\t' read -r table_schema table_name; do
    [[ -n "$table_schema" && -n "$table_name" ]] || continue
    if [[ ! "$table_schema" =~ $identifier_pattern || ! "$table_name" =~ $identifier_pattern ]]; then
      echo "Refusing to rebuild an Aria table with an unsafe identifier" >&2
      exit 1
    fi
    mariadb \
      --protocol=socket \
      --socket=/run/mysqld/mysqld.sock \
      -uroot \
      --password="$MARIADB_ROOT_PASSWORD" \
      -e "ALTER TABLE \`${table_schema}\`.\`${table_name}\` ENGINE=Aria ROW_FORMAT=PAGE"
  done <<<"$aria_tables"
  mariadb \
    --protocol=socket \
    --socket=/run/mysqld/mysqld.sock \
    -uroot \
    --password="$MARIADB_ROOT_PASSWORD" \
    -e "FLUSH PRIVILEGES"
  install -m 0400 /dev/null "$aria_encryption_marker"
fi

if [[ -n "${MARIADB_LEGACY_USER:-}" &&
      "$MARIADB_LEGACY_USER" != "$MARIADB_APP_USER" &&
      "$MARIADB_LEGACY_USER" != "$MARIADB_MIGRATION_USER" &&
      "$MARIADB_LEGACY_USER" != "$MARIADB_REFRESH_USER" &&
      "${MARIADB_RETIRE_LEGACY_USER:-false}" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn])$ ]]; then
  mariadb \
    --protocol=socket \
    --socket=/run/mysqld/mysqld.sock \
    -uroot \
    --password="$MARIADB_ROOT_PASSWORD" \
    -e "DROP USER IF EXISTS '${MARIADB_LEGACY_USER}'@'%'"
fi

if [[ "${MARIADB_CREATE_TEST_DATABASE:-false}" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn])$ ]]; then
  mariadb \
    --protocol=socket \
    --socket=/run/mysqld/mysqld.sock \
    -uroot \
    --password="$MARIADB_ROOT_PASSWORD" <<SQL
GRANT ALL PRIVILEGES ON \`test\\_${MARIADB_DATABASE}%\`.* TO '${MARIADB_MIGRATION_USER}'@'%';
SQL
fi
