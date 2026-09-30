#!/usr/bin/env bash
set -Eeuo pipefail

: "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD is required}"
: "${MARIADB_DATABASE:?MARIADB_DATABASE is required}"

identifier_pattern='^[A-Za-z0-9_]+$'
if [[ ! "$MARIADB_DATABASE" =~ $identifier_pattern ]]; then
  echo "MariaDB database names may contain only letters, numbers, and underscores" >&2
  exit 1
fi

encryption_timeout="${MARIADB_ENCRYPTION_MIGRATION_TIMEOUT:-21600}"
if [[ ! "$encryption_timeout" =~ ^[0-9]+$ || "$encryption_timeout" -lt 1 ]]; then
  echo "MARIADB_ENCRYPTION_MIGRATION_TIMEOUT must be a positive integer" >&2
  exit 1
fi

case "${MARIADB_REQUIRE_SECURE_TRANSPORT:-ON}" in
  ON|on|true|TRUE|True|1) expected_secure_transport=1 ;;
  OFF|off|false|FALSE|False|0) expected_secure_transport=0 ;;
  *)
    echo "MARIADB_REQUIRE_SECURE_TRANSPORT must be ON or OFF" >&2
    exit 1
    ;;
esac

database_command=(
  mariadb
  --protocol=socket
  --socket=/run/mysqld/mysqld.sock
  --batch
  --skip-column-names
  -uroot
  --password="$MARIADB_ROOT_PASSWORD"
)

audit_active="$(
  "${database_command[@]}" -e "SHOW GLOBAL STATUS LIKE 'Server_audit_active'" \
    | awk '{print $2}'
)"
if [[ ! "$audit_active" =~ ^(ON|1)$ ]]; then
  echo "MariaDB audit logging is not active" >&2
  exit 1
fi

active_security_plugins="$(
  "${database_command[@]}" -e "SELECT COUNT(*)
    FROM information_schema.PLUGINS
    WHERE PLUGIN_NAME IN ('SERVER_AUDIT', 'file_key_management')
      AND PLUGIN_STATUS = 'ACTIVE'"
)"
if [[ "$active_security_plugins" != "2" ]]; then
  echo "MariaDB audit or key-management plugin is not active" >&2
  exit 1
fi

security_state="$(
  "${database_command[@]}" -e "SELECT
    @@have_ssl,
    @@require_secure_transport,
    @@innodb_encrypt_tables,
    @@innodb_encrypt_log,
    @@innodb_encrypt_temporary_tables,
    @@aria_encrypt_tables,
    @@encrypt_tmp_disk_tables,
    @@encrypt_tmp_files,
    @@encrypt_binlog"
)"
read -r have_ssl secure_transport encrypt_tables encrypt_log encrypt_innodb_temp \
  encrypt_aria encrypt_tmp_disk encrypt_tmp_files encrypt_binlog <<<"$security_state"
if [[ "$have_ssl" != "YES" || "$secure_transport" != "$expected_secure_transport" ||
      "$encrypt_tables" != "FORCE" ||
      "$encrypt_log" != "1" || "$encrypt_innodb_temp" != "1" ||
      "$encrypt_aria" != "1" || "$encrypt_tmp_disk" != "1" ||
      "$encrypt_tmp_files" != "1" || "$encrypt_binlog" != "1" ]]; then
  echo "MariaDB TLS configuration or at-rest encryption safeguards are not active" >&2
  exit 1
fi

if [[ ! -f /var/lib/mysql/.intelvia-aria-encrypted-v1 ]]; then
  echo "Existing MariaDB Aria tables have not been rebuilt under encryption" >&2
  exit 1
fi

deadline=$((SECONDS + encryption_timeout))
while true; do
  unencrypted_innodb_tables="$(
    "${database_command[@]}" -e "SELECT COUNT(*)
      FROM information_schema.TABLES AS tables_found
      LEFT JOIN information_schema.INNODB_TABLESPACES_ENCRYPTION AS encryption
        ON encryption.NAME = CONCAT(tables_found.TABLE_SCHEMA, '/', tables_found.TABLE_NAME)
      WHERE tables_found.TABLE_SCHEMA = '${MARIADB_DATABASE}'
        AND tables_found.ENGINE = 'InnoDB'
        AND (
          COALESCE(encryption.ENCRYPTION_SCHEME, 0) <> 1
          OR COALESCE(encryption.ROTATING_OR_FLUSHING, 0) <> 0
        )"
  )"
  system_tablespace_state="$(
    "${database_command[@]}" -e "SELECT COUNT(*)
      FROM information_schema.INNODB_TABLESPACES_ENCRYPTION
      WHERE NAME = 'innodb_system'
        AND (
          COALESCE(ENCRYPTION_SCHEME, 0) <> 1
          OR COALESCE(ROTATING_OR_FLUSHING, 0) <> 0
        )"
  )"
  system_tablespace_count="$(
    "${database_command[@]}" -e "SELECT COUNT(*)
      FROM information_schema.INNODB_TABLESPACES_ENCRYPTION
      WHERE NAME = 'innodb_system'"
  )"
  if [[ "$unencrypted_innodb_tables" == "0" &&
        "$system_tablespace_count" == "1" &&
        "$system_tablespace_state" == "0" ]]; then
    break
  fi
  if (( SECONDS >= deadline )); then
    echo "Timed out waiting for existing InnoDB tablespaces to finish encryption: application=$unencrypted_innodb_tables system=$system_tablespace_count/$system_tablespace_state" >&2
    exit 1
  fi
  sleep 2
done

if [[ "$expected_secure_transport" == "1" ]]; then
  echo "MariaDB audit, enforced TLS, and at-rest encryption safeguards verified"
else
  echo "MariaDB audit, transitional TLS availability, and at-rest encryption safeguards verified"
fi
