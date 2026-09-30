#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/docker-compose.intelvia-app.yml" ]]; then
  DEFAULT_APP_DIR="$SCRIPT_DIR"
else
  DEFAULT_APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
APP_DIR="${APP_DIR:-$DEFAULT_APP_DIR}"
cd "$APP_DIR"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
else
  echo "$APP_DIR/.env is required" >&2
  exit 1
fi

encrypt_database_backup() {
  local output_file="$1"
  local password_file="${MARIADB_ENCRYPTION_KEY_PASSWORD_HOST_FILE:-}"
  [[ -n "$password_file" && -r "$password_file" ]] || {
    echo "MariaDB encryption password file is not readable: $password_file" >&2
    return 1
  }
  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 \
    -pass "file:$password_file" \
    -out "$output_file"
  chmod 0600 "$output_file"
  write_database_backup_hmac "$output_file"
}

decrypt_database_backup() {
  local input_file="$1"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
    -pass "file:$MARIADB_ENCRYPTION_KEY_PASSWORD_HOST_FILE" \
    -in "$input_file"
}

database_backup_hmac_key() {
  local password_file="$1"
  openssl dgst -sha256 -hex "$password_file" | awk '{print $2}'
}

write_database_backup_hmac() {
  local input_file="$1"
  local password_file="${MARIADB_ENCRYPTION_KEY_PASSWORD_HOST_FILE:-}"
  local output_file="${2:-$input_file.hmac}"
  [[ -n "$password_file" && -r "$password_file" ]] || {
    echo "MariaDB encryption password file is not readable: $password_file" >&2
    return 1
  }
  local hmac_key hmac_tmp
  hmac_key="$(database_backup_hmac_key "$password_file")"
  hmac_tmp="${output_file}.tmp"
  openssl dgst -sha256 -mac HMAC -macopt "hexkey:$hmac_key" "$input_file" \
    | awk '{print $2}' > "$hmac_tmp"
  chmod 0600 "$hmac_tmp"
  mv -f "$hmac_tmp" "$output_file"
}

verify_database_backup_hmac() {
  local input_file="$1"
  local hmac_file="${2:-$input_file.hmac}"
  local expected_hmac actual_hmac
  [[ -s "$input_file" && -s "$hmac_file" ]] || return 1
  expected_hmac="$(<"$hmac_file")"
  local hmac_key
  hmac_key="$(database_backup_hmac_key "$MARIADB_ENCRYPTION_KEY_PASSWORD_HOST_FILE")"
  actual_hmac="$(openssl dgst -sha256 -mac HMAC \
    -macopt "hexkey:$hmac_key" \
    "$input_file" | awk '{print $2}')"
  [[ "$expected_hmac" == "$actual_hmac" ]]
}

ensure_database_backup_hmac() {
  local input_file="$1"
  local hmac_file="${2:-$input_file.hmac}"
  local allow_missing="${3:-0}"
  if [[ -e "$hmac_file" ]]; then
    verify_database_backup_hmac "$input_file" "$hmac_file"
    return
  fi
  if [[ "$allow_missing" != "1" ]]; then
    echo "Authenticated backup sidecar is missing: $hmac_file" >&2
    return 1
  fi
  decrypt_database_backup "$input_file" >/dev/null
}

verify_database_backup_contents() {
  local input_file="$1"
  local expected_plaintext="$2"
  decrypt_database_backup "$input_file" | cmp -s "$expected_plaintext" -
}

publish_retained_backup() {
  local slot="$1"
  local snapshot_tmp snapshot_dir old_snapshot
  snapshot_tmp="$(mktemp -d "$APP_DIR/backups/.predeploy-$slot-$timestamp.XXXXXX")"
  snapshot_dir="$APP_DIR/backups/predeploy-$slot-$timestamp"
  cp "$backup_tmp" "$snapshot_tmp/backup.sql.enc"
  cp "$backup_tmp.hmac" "$snapshot_tmp/backup.sql.enc.hmac"
  verify_database_backup_hmac "$snapshot_tmp/backup.sql.enc"
  [[ ! -e "$snapshot_dir" ]] || { echo "Backup snapshot already exists: $snapshot_dir" >&2; return 1; }
  mv "$snapshot_tmp" "$snapshot_dir"
  for old_snapshot in "$APP_DIR/backups/predeploy-$slot-"*; do
    if [[ -d "$old_snapshot" && "$old_snapshot" != "$snapshot_dir" ]]; then
      rm -rf -- "$old_snapshot"
    fi
  done
  rm -f "$APP_DIR/backups/predeploy-$slot.sql.enc" \
    "$APP_DIR/backups/predeploy-$slot.sql.enc.hmac"
}

has_retained_backup() {
  local slot="$1"
  local snapshot_dir
  for snapshot_dir in "$APP_DIR/backups/predeploy-$slot-"*; do
    if [[ -d "$snapshot_dir" ]] && verify_database_backup_hmac "$snapshot_dir/backup.sql.enc"; then
      return 0
    fi
  done
  verify_database_backup_hmac "$APP_DIR/backups/predeploy-$slot.sql.enc"
}

STATE_DIR="${STATE_DIR:-$APP_DIR/.deploy-state}"
PARQUET_ROOT="${PARQUET_ROOT:-$APP_DIR/parquets}"
SCOPED_ARTIFACT_CACHE_PATH="${SCOPED_ARTIFACT_CACHE_PATH:-$APP_DIR/scoped-artifacts}"
[[ "$PARQUET_ROOT" == /* ]] || PARQUET_ROOT="$APP_DIR/${PARQUET_ROOT#./}"
[[ "$SCOPED_ARTIFACT_CACHE_PATH" == /* ]] || SCOPED_ARTIFACT_CACHE_PATH="$APP_DIR/${SCOPED_ARTIFACT_CACHE_PATH#./}"
NGINX_SITE_CONF="${NGINX_SITE_CONF:-/etc/nginx/sites-available/intelvia.app}"
NGINX_SITE_ENABLED="${NGINX_SITE_ENABLED:-/etc/nginx/sites-enabled/intelvia.app}"
NGINX_UPSTREAM_CONF="${NGINX_UPSTREAM_CONF:-/etc/nginx/snippets/intelvia-active-upstream.conf}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://intelvia.app}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
ROLLBACK_RETENTION_COUNT="${ROLLBACK_RETENTION_COUNT:-5}"
MIN_PARQUET_FREE_BYTES="${MIN_PARQUET_FREE_BYTES:-5368709120}"
COMPOSE=(docker compose -p intelvia -f docker-compose.intelvia-app.yml --profile tools)
SUDO=(env)

IMAGE_TAG=""
SOURCE_COMMIT=""
DEPLOY_PACKAGE_COMMIT=""
DATA_PREPARATION_MODE="auto"
MOCK_DATA_SIZE=""
DATA_CHANGES="false"
MIGRATION_CHANGES="false"
ROLLBACK_STATE=""
RECOVER_ONLY=0
BACKEND_IMAGE=""
FRONTEND_IMAGE=""
DERIVED_MUTATED=0
DERIVED_BACKUP=""
DERIVED_ORIGINAL_STATE="unknown"
DERIVED_RESTORE_FAILED=0
DERIVED_ORIGINAL_TABLES=""
DERIVED_ROLLBACK_BACKUP=""
DERIVED_ROLLBACK_ORIGINAL_STATE=""
DERIVED_ROLLBACK_TABLES=""
CUTOVER_COMPLETE=0
LEGACY_RETIREMENT_COMPLETE=0
UPSTREAM_CHANGED=0
POINTER_CHANGED=0
SITE_CONFIG_CHANGED=0
OLD_UPSTREAM=""
NEW_PARQUET_PATH=""
MIGRATION_ATTEMPTED=0
GUIDELINE_UPDATES_PAUSED=0
PENDING_FILE="$STATE_DIR/pending.env"
REQUIRED_SECURITY_GENERATION=2
TRANSITIONAL_TLS_UPGRADE=0
DERIVED_TABLES=(
  GuidelineAdherenceFacts
  GuidelineAdherence
  SurgeryCaseOutcomes
  VisitAttributes
  SurgeryCaseAttributes
)
printf -v DERIVED_TABLES_SQL "'%s'," "${DERIVED_TABLES[@]}"
DERIVED_TABLES_SQL="${DERIVED_TABLES_SQL%,}"
printf -v DERIVED_TABLES_CSV "%s," "${DERIVED_TABLES[@]}"
DERIVED_TABLES_CSV="${DERIVED_TABLES_CSV%,}"
# The demo rollback snapshot includes exactly the tables mockdata and its mapping loader replace.
MOCK_TABLES=(Patient Visit SurgeryCase BillingCode Lab Medication Transfusion AttendingProvider RoomTrace ProviderDepartmentMapping)
printf -v MOCK_TABLES_SQL "'%s'," "${MOCK_TABLES[@]}"
MOCK_TABLES_SQL="${MOCK_TABLES_SQL%,}"
printf -v MOCK_TABLES_CSV "%s," "${MOCK_TABLES[@]}"
MOCK_TABLES_CSV="${MOCK_TABLES_CSV%,}"

usage() {
  echo "Usage: $0 --image-tag TAG --source-commit SHA --package-commit SHA [--mode auto|force|reuse] [--data-changes true|false] [--migration-changes true|false] [--mock-data-size sm|md|lg]" >&2
  echo "       $0 --rollback-state DEPLOYMENT_ID" >&2
  echo "       $0 --recover-only" >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --image-tag) IMAGE_TAG="$2"; shift 2 ;;
    --source-commit) SOURCE_COMMIT="$2"; shift 2 ;;
    --package-commit) DEPLOY_PACKAGE_COMMIT="$2"; shift 2 ;;
    --mode) DATA_PREPARATION_MODE="$2"; shift 2 ;;
    --data-changes) DATA_CHANGES="$2"; shift 2 ;;
    --migration-changes) MIGRATION_CHANGES="$2"; shift 2 ;;
    --mock-data-size) MOCK_DATA_SIZE="$2"; shift 2 ;;
    --rollback-state) ROLLBACK_STATE="$2"; shift 2 ;;
    --recover-only) RECOVER_ONLY=1; shift ;;
    *) usage ;;
  esac
done

REQUESTED_DEPLOY_PACKAGE_COMMIT="$DEPLOY_PACKAGE_COMMIT"
REQUESTED_MIGRATION_CHANGES="$MIGRATION_CHANGES"

mkdir -p "$STATE_DIR/history" "$PARQUET_ROOT/.staging" "$PARQUET_ROOT/sets" \
  "$SCOPED_ARTIFACT_CACHE_PATH" "$APP_DIR/backups"

exec 9>"$STATE_DIR/deploy.lock"
flock -n 9 || { echo "Another Intelvia deployment is running" >&2; exit 1; }

PENDING_SECURITY_GENERATION=0
PENDING_DERIVED_BACKUP=""
if [[ -f "$PENDING_FILE" ]]; then
  # Older journals predate artifact encryption and still need recovery.
  # shellcheck disable=SC1090
  source "$PENDING_FILE"
  [[ "$PENDING_SECURITY_GENERATION" =~ ^[0-9]+$ ]] || {
    echo "Pending security generation must be numeric" >&2
    exit 1
  }
fi

if [[ -z "${ARTIFACT_ENCRYPTION_KEY:-}" ]]; then
  if { [[ -f "$PENDING_FILE" ]] && (( PENDING_SECURITY_GENERATION >= 2 )); } || { [[ -f "$STATE_DIR/current.env" ]] && (
    # shellcheck disable=SC1091
    source "$STATE_DIR/current.env"
    [[ "${SECURITY_GENERATION:-0}" =~ ^[0-9]+$ ]] && (( SECURITY_GENERATION >= 2 ))
  ); }; then
    echo "ARTIFACT_ENCRYPTION_KEY is missing from an established encrypted deployment" >&2
    exit 1
  fi
  for artifact in "$PARQUET_ROOT"/sets/*/visit_attributes.parquet \
    "$PARQUET_ROOT"/.staging/*/visit_attributes.parquet \
    "$SCOPED_ARTIFACT_CACHE_PATH"/guideline_adherence_overlay*.parquet; do
    [[ -f "$artifact" ]] || continue
    if [[ "$(head -c 8 "$artifact")" == "IVDATA01" ]]; then
      echo "ARTIFACT_ENCRYPTION_KEY is missing from an established encrypted deployment" >&2
      exit 1
    fi
  done
  ARTIFACT_ENCRYPTION_KEY="$(openssl rand -base64 32 | tr -d '\n')"
  printf '\nARTIFACT_ENCRYPTION_KEY=%s\n' "$ARTIFACT_ENCRYPTION_KEY" >> "$APP_DIR/.env"
fi
chmod 0600 "$APP_DIR/.env"
export ARTIFACT_ENCRYPTION_KEY

shopt -s nullglob
legacy_plaintext_backups=(
  "$APP_DIR"/backups/*.sql
  "$APP_DIR"/backups/*.sql.tmp
  "$APP_DIR"/backups/.*.sql.tmp
)
shopt -u nullglob
for plaintext_backup in "${legacy_plaintext_backups[@]}"; do
  encrypted_backup="${plaintext_backup}.enc"
  encrypted_backup_tmp="${encrypted_backup}.tmp"
  encrypted_backup_hmac="${encrypted_backup}.hmac"
  encrypted_backup_tmp_hmac="${encrypted_backup_tmp}.hmac"
  echo "Encrypting legacy plaintext database backup: $(basename "$plaintext_backup")"
  if [[ -e "$encrypted_backup" && -e "$encrypted_backup_tmp" ]]; then
    echo "Refusing to reconcile both final and temporary encrypted backups for $plaintext_backup" >&2
    exit 1
  fi
  if [[ -e "$encrypted_backup" ]]; then
    ensure_database_backup_hmac "$encrypted_backup" "$encrypted_backup_hmac" 1
    verify_database_backup_contents "$encrypted_backup" "$plaintext_backup" || {
      echo "Encrypted backup does not match legacy plaintext backup: $plaintext_backup" >&2
      exit 1
    }
    [[ -e "$encrypted_backup_hmac" ]] || write_database_backup_hmac "$encrypted_backup" "$encrypted_backup_hmac"
  elif [[ -e "$encrypted_backup_tmp" ]]; then
    ensure_database_backup_hmac "$encrypted_backup_tmp" "$encrypted_backup_tmp_hmac" 1
    verify_database_backup_contents "$encrypted_backup_tmp" "$plaintext_backup" || {
      echo "Temporary encrypted backup does not match legacy plaintext backup: $plaintext_backup" >&2
      exit 1
    }
    [[ -e "$encrypted_backup_tmp_hmac" ]] || write_database_backup_hmac "$encrypted_backup_tmp" "$encrypted_backup_tmp_hmac"
    mv "$encrypted_backup_tmp" "$encrypted_backup"
    mv "$encrypted_backup_tmp_hmac" "$encrypted_backup_hmac"
  else
    encrypt_database_backup "$encrypted_backup_tmp" < "$plaintext_backup"
    verify_database_backup_contents "$encrypted_backup_tmp" "$plaintext_backup" || {
      echo "New encrypted backup does not match legacy plaintext backup: $plaintext_backup" >&2
      exit 1
    }
    mv "$encrypted_backup_tmp" "$encrypted_backup"
    mv "$encrypted_backup_tmp_hmac" "$encrypted_backup_hmac"
  fi
  verify_database_backup_hmac "$encrypted_backup" || {
    echo "Encrypted legacy backup failed authentication: $encrypted_backup" >&2
    exit 1
  }
  if [[ "$PENDING_DERIVED_BACKUP" == "$plaintext_backup" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == PENDING_DERIVED_BACKUP=* ]]; then
        printf 'PENDING_DERIVED_BACKUP=%q\n' "$encrypted_backup"
      else
        printf '%s\n' "$line"
      fi
    done < "$PENDING_FILE" > "$PENDING_FILE.tmp"
    mv "$PENDING_FILE.tmp" "$PENDING_FILE"
    PENDING_DERIVED_BACKUP="$encrypted_backup"
  fi
  for state_file in "$STATE_DIR/current.env" "$STATE_DIR"/history/*.env; do
    [[ -f "$state_file" ]] || continue
    referenced_backup="$(
      unset DERIVED_ROLLBACK_BACKUP
      # shellcheck disable=SC1090
      source "$state_file"
      printf '%s' "${DERIVED_ROLLBACK_BACKUP:-}"
    )"
    [[ "$referenced_backup" == "$plaintext_backup" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == DERIVED_ROLLBACK_BACKUP=* ]]; then
        printf 'DERIVED_ROLLBACK_BACKUP=%q\n' "$encrypted_backup"
      else
        printf '%s\n' "$line"
      fi
    done < "$state_file" > "$state_file.tmp"
    mv "$state_file.tmp" "$state_file"
  done
  rm -f -- "$plaintext_backup"
done

if [[ "${DEPLOY_USE_SUDO:-1}" != "0" && "$(id -u)" != "0" ]]; then
  SUDO=(sudo)
fi

ACTIVE_COLOR="blue"
ACTIVE_IMAGE_TAG=""
ACTIVE_SOURCE_COMMIT="unknown"
ACTIVE_PARQUET_SET=""
ACTIVE_BACKEND_IMAGE=""
ACTIVE_FRONTEND_IMAGE=""
SCHEMA_GENERATION=0
SECURITY_GENERATION=0
GUIDELINE_CONFIG_VERSION=""
GUIDELINE_PREVIOUS_PUBLISHED_VERSION=""
GUIDELINE_PREVIOUS_CACHE_VERSION=""
GUIDELINE_PREVIOUS_STATUS=""
GUIDELINE_PUBLISHED_VERSION=""
GUIDELINE_CACHE_VERSION=""
GUIDELINE_STATUS=""
GUIDELINE_TARGET_PUBLISHED_VERSION=""
GUIDELINE_TARGET_CACHE_VERSION=""
GUIDELINE_TARGET_STATUS=""
DEPLOY_PACKAGE_COMMIT="${DEPLOY_PACKAGE_COMMIT:-}"
MIGRATION_CHANGES="${MIGRATION_CHANGES:-false}"
PREVIOUS_COLOR=""
PREVIOUS_IMAGE_TAG=""
PREVIOUS_SOURCE_COMMIT=""
PREVIOUS_PARQUET_SET=""
STATE_LOADED=0
if [[ -f "$STATE_DIR/current.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/current.env"
  STATE_LOADED=1
fi
if [[ "$RECOVER_ONLY" == "1" ]]; then
  if [[ "$STATE_LOADED" == "0" && ! -f "$PENDING_FILE" ]]; then
    echo "Deployment recovery complete"
    exit 0
  fi
  if [[ "$STATE_LOADED" == "0" ]]; then
    # A first deployment can fail after writing pending.env but before it has
    # committed current.env. Seed only the Compose interpolation needed to
    # stop the candidate and restore the journaled pre-cutover state.
    # shellcheck disable=SC1090
    source "$PENDING_FILE"
    ACTIVE_COLOR="$PENDING_ACTIVE_COLOR"
    ACTIVE_PARQUET_SET="$PENDING_ACTIVE_PARQUET_SET"
    IMAGE_TAG="$PENDING_IMAGE_TAG"
    SOURCE_COMMIT="${PENDING_SOURCE_COMMIT:-unknown}"
    DEPLOY_PACKAGE_COMMIT="${PENDING_DEPLOY_PACKAGE_COMMIT:-}"
    if [[ -z "$DEPLOY_PACKAGE_COMMIT" ]]; then
      DEPLOY_PACKAGE_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf '0%.0s' {1..40})"
    fi
    recovery_digest="$(printf '0%.0s' {1..64})"
    BACKEND_IMAGE="${PENDING_BACKEND_IMAGE:-docker.io/intelvia/intelvia-backend@sha256:$recovery_digest}"
    FRONTEND_IMAGE="${PENDING_FRONTEND_IMAGE:-docker.io/intelvia/intelvia-frontend@sha256:$recovery_digest}"
  else
    IMAGE_TAG="$ACTIVE_IMAGE_TAG"
    SOURCE_COMMIT="$ACTIVE_SOURCE_COMMIT"
    BACKEND_IMAGE="$ACTIVE_BACKEND_IMAGE"
    FRONTEND_IMAGE="$ACTIVE_FRONTEND_IMAGE"
  fi
  DATA_PREPARATION_MODE="reuse"
  DATA_CHANGES="false"
  MIGRATION_CHANGES="false"
elif [[ -z "$ROLLBACK_STATE" ]]; then
  DEPLOY_PACKAGE_COMMIT="$REQUESTED_DEPLOY_PACKAGE_COMMIT"
  MIGRATION_CHANGES="$REQUESTED_MIGRATION_CHANGES"
  if [[ "$IMAGE_TAG" == "$ACTIVE_IMAGE_TAG" && "$SOURCE_COMMIT" == "$ACTIVE_SOURCE_COMMIT" ]]; then
    BACKEND_IMAGE="$ACTIVE_BACKEND_IMAGE"
    FRONTEND_IMAGE="$ACTIVE_FRONTEND_IMAGE"
  fi
fi

NGINX_ACTIVE_COLOR=""
if [[ -f "$NGINX_UPSTREAM_CONF" ]]; then
  if rg -q '127\.0\.0\.1:8081' "$NGINX_UPSTREAM_CONF" 2>/dev/null || grep -q '127\.0\.0\.1:8081' "$NGINX_UPSTREAM_CONF"; then
    NGINX_ACTIVE_COLOR="green"
  elif rg -q '127\.0\.0\.1:8080' "$NGINX_UPSTREAM_CONF" 2>/dev/null || grep -q '127\.0\.0\.1:8080' "$NGINX_UPSTREAM_CONF"; then
    NGINX_ACTIVE_COLOR="blue"
  fi
fi
if [[ "$STATE_LOADED" == "1" && -n "$NGINX_ACTIVE_COLOR" && "$NGINX_ACTIVE_COLOR" != "$ACTIVE_COLOR" && ! -f "$PENDING_FILE" ]]; then
  echo "Deployment state says $ACTIVE_COLOR but nginx routes to $NGINX_ACTIVE_COLOR; reconcile before deploying" >&2
  exit 1
elif [[ "$STATE_LOADED" == "0" && -n "$NGINX_ACTIVE_COLOR" ]]; then
  ACTIVE_COLOR="$NGINX_ACTIVE_COLOR"
fi

if [[ -n "$ROLLBACK_STATE" ]]; then
  [[ "$ROLLBACK_STATE" =~ ^[0-9]{8}T[0-9]{6}Z-(sha-[0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?)$ ]] || {
    echo "Invalid rollback deployment ID" >&2
    exit 2
  }
  rollback_file="$STATE_DIR/history/$ROLLBACK_STATE.env"
  [[ -f "$rollback_file" ]] || { echo "Unknown rollback state: $ROLLBACK_STATE" >&2; exit 1; }
  CURRENT_ACTIVE_COLOR="$ACTIVE_COLOR"
  CURRENT_ACTIVE_IMAGE_TAG="$ACTIVE_IMAGE_TAG"
  CURRENT_ACTIVE_SOURCE_COMMIT="$ACTIVE_SOURCE_COMMIT"
  CURRENT_ACTIVE_PARQUET_SET="$ACTIVE_PARQUET_SET"
  CURRENT_ACTIVE_BACKEND_IMAGE="$ACTIVE_BACKEND_IMAGE"
  CURRENT_ACTIVE_FRONTEND_IMAGE="$ACTIVE_FRONTEND_IMAGE"
  CURRENT_DEPLOY_PACKAGE_COMMIT="$DEPLOY_PACKAGE_COMMIT"
  CURRENT_MIGRATION_CHANGES="$MIGRATION_CHANGES"
  CURRENT_SCHEMA_GENERATION="$SCHEMA_GENERATION"
  CURRENT_SECURITY_GENERATION="$SECURITY_GENERATION"
  SECURITY_GENERATION=0
  CURRENT_PREVIOUS_PARQUET_SET="$PREVIOUS_PARQUET_SET"
  CURRENT_DERIVED_ROLLBACK_BACKUP="${DERIVED_ROLLBACK_BACKUP:-}"
  CURRENT_DERIVED_ROLLBACK_ORIGINAL_STATE="${DERIVED_ROLLBACK_ORIGINAL_STATE:-}"
  CURRENT_DERIVED_ROLLBACK_TABLES="${DERIVED_ROLLBACK_TABLES:-}"
  # shellcheck disable=SC1090
  source "$rollback_file"
  TARGET_IMAGE_TAG="$ACTIVE_IMAGE_TAG"
  TARGET_SOURCE_COMMIT="$ACTIVE_SOURCE_COMMIT"
  TARGET_PARQUET_SET="$ACTIVE_PARQUET_SET"
  TARGET_BACKEND_IMAGE="$ACTIVE_BACKEND_IMAGE"
  TARGET_FRONTEND_IMAGE="$ACTIVE_FRONTEND_IMAGE"
  TARGET_DEPLOY_PACKAGE_COMMIT="$DEPLOY_PACKAGE_COMMIT"
  TARGET_SCHEMA_GENERATION="${SCHEMA_GENERATION:-0}"
  TARGET_SECURITY_GENERATION="$SECURITY_GENERATION"
  if [[ "$TARGET_SCHEMA_GENERATION" != "$CURRENT_SCHEMA_GENERATION" ]]; then
    echo "Rollback is blocked across a Django migration boundary" >&2
    exit 1
  fi
  if [[ "$TARGET_SECURITY_GENERATION" != "$CURRENT_SECURITY_GENERATION" ]]; then
    echo "Rollback is blocked across a security boundary" >&2
    exit 1
  fi
  ACTIVE_COLOR="$CURRENT_ACTIVE_COLOR"
  ACTIVE_IMAGE_TAG="$CURRENT_ACTIVE_IMAGE_TAG"
  ACTIVE_SOURCE_COMMIT="$CURRENT_ACTIVE_SOURCE_COMMIT"
  ACTIVE_PARQUET_SET="$CURRENT_ACTIVE_PARQUET_SET"
  ACTIVE_BACKEND_IMAGE="$CURRENT_ACTIVE_BACKEND_IMAGE"
  ACTIVE_FRONTEND_IMAGE="$CURRENT_ACTIVE_FRONTEND_IMAGE"
  IMAGE_TAG="$TARGET_IMAGE_TAG"
  SOURCE_COMMIT="$TARGET_SOURCE_COMMIT"
  ROLLBACK_PARQUET_SET="$TARGET_PARQUET_SET"
  BACKEND_IMAGE="$TARGET_BACKEND_IMAGE"
  FRONTEND_IMAGE="$TARGET_FRONTEND_IMAGE"
  DEPLOY_PACKAGE_COMMIT="$TARGET_DEPLOY_PACKAGE_COMMIT"
  MIGRATION_CHANGES="false"
  CANDIDATE_SCHEMA_GENERATION="$TARGET_SCHEMA_GENERATION"
  CANDIDATE_SECURITY_GENERATION="$TARGET_SECURITY_GENERATION"
  DATA_PREPARATION_MODE="reuse"
  ROLLBACK_RESTORES_DERIVED=0
  if [[ "$TARGET_PARQUET_SET" != "$CURRENT_ACTIVE_PARQUET_SET" ]]; then
    if [[ "$TARGET_PARQUET_SET" != "$CURRENT_PREVIOUS_PARQUET_SET" ]]; then
      echo "Data rollback is limited to the immediately previous parquet generation" >&2
      exit 1
    fi
    if [[ "$CURRENT_DERIVED_ROLLBACK_ORIGINAL_STATE" == "present" ]]; then
      [[ -s "$CURRENT_DERIVED_ROLLBACK_BACKUP" ]] || {
        echo "The retained rollback state is missing its derived-table snapshot" >&2
        exit 1
      }
    elif [[ "$CURRENT_DERIVED_ROLLBACK_ORIGINAL_STATE" != "zero" ]]; then
      echo "The retained rollback state has no usable derived-table snapshot" >&2
      exit 1
    fi
    ROLLBACK_RESTORES_DERIVED=1
    ROLLBACK_DERIVED_BACKUP="$CURRENT_DERIVED_ROLLBACK_BACKUP"
    ROLLBACK_DERIVED_ORIGINAL_STATE="$CURRENT_DERIVED_ROLLBACK_ORIGINAL_STATE"
    ROLLBACK_DERIVED_TABLES="$CURRENT_DERIVED_ROLLBACK_TABLES"
  fi
fi

[[ "$IMAGE_TAG" =~ ^sha-[0-9a-f]{40}$ || "$IMAGE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Image tag must be an immutable sha-* or semantic version tag" >&2
  exit 1
}
[[ -n "$SOURCE_COMMIT" ]] || usage
[[ "$DEPLOY_PACKAGE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "Deploy package commit must be a full Git SHA" >&2; exit 1; }
[[ "$DATA_PREPARATION_MODE" =~ ^(auto|force|reuse)$ ]] || usage
[[ "$DATA_CHANGES" =~ ^(true|false)$ ]] || usage
[[ "$MIGRATION_CHANGES" =~ ^(true|false)$ ]] || usage
if [[ -n "$MOCK_DATA_SIZE" ]]; then
  [[ "$MOCK_DATA_SIZE" =~ ^(sm|md|lg)$ ]] || usage
  [[ "${DJANGO_HOSTNAME:-}" == "intelvia.app" && "$PUBLIC_BASE_URL" == "https://intelvia.app" \
    && "$DATA_PREPARATION_MODE" == "force" && -z "$ROLLBACK_STATE" && "$RECOVER_ONLY" == "0" ]] || {
    echo "Mock data regeneration requires a forced intelvia.app demo refresh" >&2
    exit 1
  }
fi
[[ "$ROLLBACK_RETENTION_COUNT" =~ ^[0-9]+$ && "$ROLLBACK_RETENTION_COUNT" -ge 2 ]] || { echo "ROLLBACK_RETENTION_COUNT must be at least 2" >&2; exit 1; }
[[ "$MIN_PARQUET_FREE_BYTES" =~ ^[0-9]+$ ]] || { echo "MIN_PARQUET_FREE_BYTES must be numeric" >&2; exit 1; }
[[ "$SCHEMA_GENERATION" =~ ^[0-9]+$ ]] || { echo "SCHEMA_GENERATION must be numeric" >&2; exit 1; }
[[ "$SECURITY_GENERATION" =~ ^[0-9]+$ ]] || { echo "SECURITY_GENERATION must be numeric" >&2; exit 1; }
if [[ -z "${CANDIDATE_SCHEMA_GENERATION:-}" ]]; then
  CANDIDATE_SCHEMA_GENERATION="$SCHEMA_GENERATION"
  if [[ "$MIGRATION_CHANGES" == "true" ]]; then
    CANDIDATE_SCHEMA_GENERATION=$((CANDIDATE_SCHEMA_GENERATION + 1))
  fi
fi
if [[ -z "${CANDIDATE_SECURITY_GENERATION:-}" ]]; then
  CANDIDATE_SECURITY_GENERATION="$REQUIRED_SECURITY_GENERATION"
fi
if [[ "$STATE_LOADED" == "1" && "$SECURITY_GENERATION" -lt 1 ]]; then
  TRANSITIONAL_TLS_UPGRADE=1
  MARIADB_REQUIRE_SECURE_TRANSPORT=OFF
else
  MARIADB_REQUIRE_SECURE_TRANSPORT=ON
fi
export MARIADB_REQUIRE_SECURE_TRANSPORT

other_color() { [[ "$1" == "blue" ]] && echo green || echo blue; }
port_for_color() { [[ "$1" == "blue" ]] && echo 8080 || echo 8081; }
frontend_for_color() { echo "frontend-$1"; }
backend_for_color() { echo "backend-$1"; }

smoke_candidate_frontend() {
  local base_url="$1"
  local index_file="$STATE_DIR/.candidate-index-$timestamp.html"
  local bundle_file="$STATE_DIR/.candidate-bundle-$timestamp.js"
  local asset_path

  curl -fsS --max-time 8 -H 'Host: intelvia.app' -H 'X-Forwarded-Proto: https' \
    "$base_url/" -o "$index_file"
  asset_path="$(sed -n 's|.*src="\(/assets/[^"?]*\.js\)[^"]*".*|\1|p' "$index_file" | head -n 1)"
  [[ "$asset_path" == /assets/*.js ]] || {
    echo "Candidate frontend did not serve a Vite application bundle" >&2
    return 1
  }
  curl -fsS --max-time 20 -H 'Host: intelvia.app' -H 'X-Forwarded-Proto: https' \
    "$base_url$asset_path" -o "$bundle_file"
  if ! rg -F -q -- "$IMAGE_TAG" "$bundle_file" 2>/dev/null \
    && ! grep -F -q -- "$IMAGE_TAG" "$bundle_file"; then
    echo "Candidate frontend bundle does not contain the requested immutable image tag" >&2
    return 1
  fi
  rm -f "$index_file" "$bundle_file"
}

smoke_auth() {
  local base_url="$1"
  "$SCRIPT_DIR/check-cas-redirect.sh" "$base_url"
}

NEXT_COLOR="$(other_color "$ACTIVE_COLOR")"
ACTIVE_PORT="$(port_for_color "$ACTIVE_COLOR")"
NEXT_PORT="$(port_for_color "$NEXT_COLOR")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
PARQUET_SET_ID="$IMAGE_TAG-$timestamp"
NGINX_BACKUP_DIR="$STATE_DIR/.nginx-backup-$timestamp"

if [[ -z "$ACTIVE_PARQUET_SET" ]]; then
  if [[ -L "$PARQUET_ROOT/current" ]]; then
    ACTIVE_PARQUET_SET="$(readlink -f "$PARQUET_ROOT/current")"
  elif [[ -d "$APP_DIR/backend/parquet_cache" ]]; then
    bootstrap_set="$PARQUET_ROOT/sets/bootstrap"
    mkdir -p "$bootstrap_set"
    cp -a "$APP_DIR/backend/parquet_cache/." "$bootstrap_set/"
    ACTIVE_PARQUET_SET="$bootstrap_set"
  else
    echo "No active parquet set exists; run a forced data preparation" >&2
    ACTIVE_PARQUET_SET="$PARQUET_ROOT/sets/bootstrap"
    mkdir -p "$ACTIVE_PARQUET_SET"
  fi
fi

PREPARE_DATA=false
if [[ "$DATA_PREPARATION_MODE" == "force" ]] || { [[ "$DATA_PREPARATION_MODE" == "auto" ]] && [[ "$DATA_CHANGES" == "true" ]]; }; then
  PREPARE_DATA=true
fi
if [[ "$SECURITY_GENERATION" -lt 2 && "$RECOVER_ONLY" != "1" ]]; then
  [[ "$DATA_PREPARATION_MODE" != "reuse" ]] || {
    echo "Encrypted artifacts require fresh data preparation" >&2
    exit 1
  }
  PREPARE_DATA=true
fi

if [[ "$DATA_PREPARATION_MODE" == "reuse" && -n "${ROLLBACK_PARQUET_SET:-}" ]]; then
  CANDIDATE_PARQUET_SET="$ROLLBACK_PARQUET_SET"
elif [[ "$PREPARE_DATA" == "true" ]]; then
  CANDIDATE_PARQUET_SET="$PARQUET_ROOT/.staging/$PARQUET_SET_ID"
else
  CANDIDATE_PARQUET_SET="$ACTIVE_PARQUET_SET"
fi
export WORKER_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"

resolve_digest_image() {
  local repository="$1"
  local tag_ref="$repository:$IMAGE_TAG"
  local digest_ref
  docker pull "$tag_ref" >/dev/null
  digest_ref="$(docker image inspect --format '{{index .RepoDigests 0}}' "$tag_ref")"
  [[ "$digest_ref" =~ ^(docker\.io/)?${repository#docker.io/}@sha256:[0-9a-f]{64}$ ]] || {
    echo "Could not resolve an immutable digest for $tag_ref" >&2
    return 1
  }
  printf '%s\n' "$digest_ref"
}

if [[ -z "$BACKEND_IMAGE" ]]; then
  BACKEND_IMAGE="$(resolve_digest_image docker.io/intelvia/intelvia-backend)"
fi
if [[ -z "$FRONTEND_IMAGE" ]]; then
  FRONTEND_IMAGE="$(resolve_digest_image docker.io/intelvia/intelvia-frontend)"
fi
[[ "$BACKEND_IMAGE" =~ ^(docker\.io/)?intelvia/intelvia-backend@sha256:[0-9a-f]{64}$ ]] || { echo "Invalid backend digest reference" >&2; exit 1; }
[[ "$FRONTEND_IMAGE" =~ ^(docker\.io/)?intelvia/intelvia-frontend@sha256:[0-9a-f]{64}$ ]] || { echo "Invalid frontend digest reference" >&2; exit 1; }

export COMPOSE_PROJECT_NAME=intelvia INTELVIA_IMAGE_TAG="$IMAGE_TAG" INTELVIA_SOURCE_COMMIT="$SOURCE_COMMIT"
export INTELVIA_BACKEND_IMAGE="$BACKEND_IMAGE" INTELVIA_FRONTEND_IMAGE="$FRONTEND_IMAGE"
export SCOPED_ARTIFACT_CACHE_PATH
export BLUE_PARQUET_SET_PATH="$ACTIVE_PARQUET_SET" GREEN_PARQUET_SET_PATH="$ACTIVE_PARQUET_SET"
if [[ "$NEXT_COLOR" == "blue" ]]; then
  BLUE_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"
else
  GREEN_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"
fi
export BLUE_PARQUET_SET_PATH GREEN_PARQUET_SET_PATH

query_derived_tables() {
  local tables_sql="${1:-$DERIVED_TABLES_SQL}"
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
    mariadb -N -uroot \
    -e "SELECT table_name FROM information_schema.tables WHERE table_schema='$MARIADB_DATABASE' AND table_name IN ($tables_sql) ORDER BY FIELD(table_name, $tables_sql)"
}

backup_derived_tables() {
  local backup_path="$1"
  local existing_derived
  local existing_derived_tables=()

  local tables_sql="$DERIVED_TABLES_SQL"
  if [[ -n "$MOCK_DATA_SIZE" || "${ROLLBACK_DERIVED_TABLES:-}" == *Patient* ]]; then
    tables_sql+=",$MOCK_TABLES_SQL"
  fi
  existing_derived="$(query_derived_tables "$tables_sql")"
  DERIVED_ORIGINAL_TABLES="$existing_derived"
  if [[ -n "$existing_derived" ]]; then
    while IFS= read -r table_name; do
      existing_derived_tables+=("$table_name")
    done <<< "$existing_derived"
    DERIVED_ORIGINAL_STATE="present"
    "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
      mariadb-dump -uroot --single-transaction "$MARIADB_DATABASE" \
      "${existing_derived_tables[@]}" | encrypt_database_backup "$backup_path"
  else
    DERIVED_ORIGINAL_STATE="zero"
    rm -f "$backup_path" "$backup_path.hmac"
  fi
}

restore_derived_snapshot() {
  local original_state="$1"
  local backup_path="$2"
  local expected_tables="$3"
  local restored_tables

  if [[ "$original_state" == "three" ]]; then
    original_state="present"
    expected_tables=$'GuidelineAdherence\nVisitAttributes\nSurgeryCaseAttributes'
  elif [[ "$original_state" == "four" ]]; then
    original_state="present"
    expected_tables=$'GuidelineAdherenceFacts\nGuidelineAdherence\nVisitAttributes\nSurgeryCaseAttributes'
  fi

  local tables_sql="$DERIVED_TABLES_SQL"
  local tables_csv="$DERIVED_TABLES_CSV"
  if [[ "$expected_tables" == *Patient* ]]; then
    tables_sql+=",$MOCK_TABLES_SQL"
    tables_csv+=",$MOCK_TABLES_CSV"
  fi

  if [[ "$original_state" == "present" ]]; then
    [[ -s "$backup_path" ]] || {
      echo "Derived-table snapshot is missing or empty: $backup_path" >&2
      return 1
    }
    [[ -n "$expected_tables" ]] || {
      echo "Derived-table snapshot has no expected table inventory" >&2
      return 1
    }
    ensure_database_backup_hmac "$backup_path" || return 1
    echo "Restoring pre-deployment derived tables"
    "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
      mariadb -uroot "$MARIADB_DATABASE" \
      -e "SET FOREIGN_KEY_CHECKS=0; DROP TABLE IF EXISTS $tables_csv; SET FOREIGN_KEY_CHECKS=1" || return 1
    decrypt_database_backup "$backup_path" | \
      "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
        mariadb -uroot "$MARIADB_DATABASE" || return 1
  elif [[ "$original_state" == "zero" ]]; then
    echo "Removing derived tables created by the failed deployment"
    "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
      mariadb -uroot "$MARIADB_DATABASE" \
      -e "SET FOREIGN_KEY_CHECKS=0; DROP TABLE IF EXISTS $tables_csv; SET FOREIGN_KEY_CHECKS=1" || return 1
  else
    echo "Unknown derived-table restore state: $original_state" >&2
    return 1
  fi

  restored_tables="$(query_derived_tables "$tables_sql")"
  if [[ "$restored_tables" != "$expected_tables" ]]; then
    echo "Derived-table restore verification failed" >&2
    echo "Expected tables: ${expected_tables:-<none>}" >&2
    echo "Restored tables: ${restored_tables:-<none>}" >&2
    return 1
  fi
}

restore_derived_tables() {
  if [[ "$DERIVED_RESTORE_FAILED" == "1" ]]; then
    return 1
  fi
  if [[ "$DERIVED_MUTATED" != "1" ]]; then
    return 0
  fi
  if ! restore_derived_snapshot \
    "$DERIVED_ORIGINAL_STATE" "$DERIVED_BACKUP" "$DERIVED_ORIGINAL_TABLES"; then
    DERIVED_RESTORE_FAILED=1
    return 1
  fi
}

copy_guideline_overlay_generation() {
  local source_set="$1"
  local target_set="$2"
  local cache_version="$3"
  local file_name
  local source_dir="$source_set/guideline-overlays"
  local target_dir="$target_set/guideline-overlays"

  [[ -n "$cache_version" ]] || return 0
  [[ "$cache_version" != */* && "$cache_version" != "." && "$cache_version" != ".." ]] || {
    echo "Invalid guideline overlay cache version" >&2
    return 1
  }
  if [[ ! -f "$source_dir/guideline_adherence_overlay.v${cache_version}.parquet" \
    || ! -f "$source_dir/guideline_adherence_overlay.v${cache_version}.json" ]]; then
    source_dir="$source_set"
  fi
  mkdir -p "$target_dir"
  for file_name in \
    "guideline_adherence_overlay.v${cache_version}.parquet" \
    "guideline_adherence_overlay.v${cache_version}.json"; do
    [[ -f "$source_dir/$file_name" ]] || {
      echo "Active guideline overlay generation is incomplete: $source_dir/$file_name" >&2
      return 1
    }
    if [[ "$source_dir" != "$target_dir" ]]; then
      cp -p "$source_dir/$file_name" "$target_dir/$file_name"
    fi
  done
  if [[ "$source_set" == "$target_set" ]]; then
    cp -p "$target_dir/guideline_adherence_overlay.v${cache_version}.json" \
      "$target_dir/guideline_adherence_overlay.json.tmp"
    mv -f "$target_dir/guideline_adherence_overlay.json.tmp" \
      "$target_dir/guideline_adherence_overlay.json"
  fi
}

restore_nginx_config() {
  if [[ "$UPSTREAM_CHANGED" != "1" && "$SITE_CONFIG_CHANGED" != "1" ]]; then
    return
  fi
  if [[ "$UPSTREAM_CHANGED" == "1" ]]; then
    printf '%s\n' "$OLD_UPSTREAM" | "${SUDO[@]}" tee "$NGINX_UPSTREAM_CONF" >/dev/null || true
  fi
  if [[ "$SITE_CONFIG_CHANGED" == "1" ]]; then
    "${SUDO[@]}" rm -rf "$NGINX_SITE_CONF" "$NGINX_SITE_ENABLED" || true
    if [[ -e "$NGINX_BACKUP_DIR/site.conf" || -L "$NGINX_BACKUP_DIR/site.conf" ]]; then
      "${SUDO[@]}" cp -a "$NGINX_BACKUP_DIR/site.conf" "$NGINX_SITE_CONF" || true
    fi
    if [[ -e "$NGINX_BACKUP_DIR/site.enabled" || -L "$NGINX_BACKUP_DIR/site.enabled" ]]; then
      "${SUDO[@]}" cp -a "$NGINX_BACKUP_DIR/site.enabled" "$NGINX_SITE_ENABLED" || true
    fi
  fi
  "${SUDO[@]}" nginx -t >/dev/null 2>&1 && "${SUDO[@]}" systemctl reload nginx || true
}

restore_legacy_database_transport() {
  if [[ "$TRANSITIONAL_TLS_UPGRADE" != "1" ]]; then
    return 0
  fi
  echo "Restoring legacy-compatible MariaDB transport before routing to the previous application"
  MARIADB_REQUIRE_SECURE_TRANSPORT=OFF
  export MARIADB_REQUIRE_SECURE_TRANSPORT
  "${COMPOSE[@]}" up -d --force-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" mariadb
}

restore_active_celery_worker() {
  if [[ -n "$ACTIVE_BACKEND_IMAGE" ]]; then
    INTELVIA_BACKEND_IMAGE="$ACTIVE_BACKEND_IMAGE" \
      INTELVIA_IMAGE_TAG="$ACTIVE_IMAGE_TAG" \
      INTELVIA_SOURCE_COMMIT="$ACTIVE_SOURCE_COMMIT" \
      WORKER_PARQUET_SET_PATH="$ACTIVE_PARQUET_SET" \
      "${COMPOSE[@]}" up -d --force-recreate celery-worker >/dev/null
  else
    "${COMPOSE[@]}" stop celery-worker >/dev/null 2>&1 || true
  fi
}

write_pending_state() {
  {
    printf 'PENDING_ACTIVE_COLOR=%q\n' "$ACTIVE_COLOR"
    printf 'PENDING_ACTIVE_PARQUET_SET=%q\n' "$ACTIVE_PARQUET_SET"
    printf 'PENDING_NEXT_COLOR=%q\n' "$NEXT_COLOR"
    printf 'PENDING_NEW_PARQUET_PATH=%q\n' "$NEW_PARQUET_PATH"
    printf 'PENDING_DERIVED_MUTATED=%q\n' "$DERIVED_MUTATED"
    printf 'PENDING_DERIVED_BACKUP=%q\n' "$DERIVED_BACKUP"
    printf 'PENDING_DERIVED_ORIGINAL_STATE=%q\n' "$DERIVED_ORIGINAL_STATE"
    printf 'PENDING_DERIVED_ORIGINAL_TABLES=%q\n' "$DERIVED_ORIGINAL_TABLES"
    printf 'PENDING_MIGRATION_CHANGES=%q\n' "$MIGRATION_CHANGES"
    printf 'PENDING_MIGRATION_ATTEMPTED=%q\n' "$MIGRATION_ATTEMPTED"
    printf 'PENDING_SCHEMA_GENERATION=%q\n' "$CANDIDATE_SCHEMA_GENERATION"
    printf 'PENDING_SECURITY_GENERATION=%q\n' "$CANDIDATE_SECURITY_GENERATION"
    printf 'PENDING_PREVIOUS_SECURITY_GENERATION=%q\n' "$SECURITY_GENERATION"
    printf 'PENDING_CUTOVER_COMPLETE=%q\n' "$CUTOVER_COMPLETE"
    printf 'PENDING_IMAGE_TAG=%q\n' "$IMAGE_TAG"
    printf 'PENDING_SOURCE_COMMIT=%q\n' "$SOURCE_COMMIT"
    printf 'PENDING_DEPLOY_PACKAGE_COMMIT=%q\n' "$DEPLOY_PACKAGE_COMMIT"
    printf 'PENDING_BACKEND_IMAGE=%q\n' "$BACKEND_IMAGE"
    printf 'PENDING_FRONTEND_IMAGE=%q\n' "$FRONTEND_IMAGE"
    printf 'PENDING_TARGET_DEPLOYMENT_ID=%q\n' "$timestamp-$IMAGE_TAG"
    printf 'PENDING_GUIDELINE_CONFIG_VERSION=%q\n' "$GUIDELINE_CONFIG_VERSION"
    printf 'PENDING_GUIDELINE_PREVIOUS_PUBLISHED_VERSION=%q\n' "$GUIDELINE_PREVIOUS_PUBLISHED_VERSION"
    printf 'PENDING_GUIDELINE_PREVIOUS_CACHE_VERSION=%q\n' "$GUIDELINE_PREVIOUS_CACHE_VERSION"
    printf 'PENDING_GUIDELINE_PREVIOUS_STATUS=%q\n' "$GUIDELINE_PREVIOUS_STATUS"
    printf 'PENDING_GUIDELINE_UPDATES_PAUSED=%q\n' "$GUIDELINE_UPDATES_PAUSED"
  } > "$PENDING_FILE.tmp"
  mv "$PENDING_FILE.tmp" "$PENDING_FILE"
}

retire_legacy_database_account() {
  if [[ "$LEGACY_RETIREMENT_COMPLETE" == "1" ]]; then
    return
  fi
  echo "Retiring obsolete MariaDB application account"
  "${COMPOSE[@]}" run --rm -e MARIADB_RETIRE_LEGACY_USER=true mariadb-provision
  LEGACY_RETIREMENT_COMPLETE=1
}

finish_artifact_encryption_upgrade() {
  local previous_generation="$1"
  local target_generation="$2"
  local encrypted_set="$3"
  [[ "$previous_generation" -lt 2 && "$target_generation" -ge 2 ]] || return 0
  export TOOL_PARQUET_SET_PATH="$encrypted_set"
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py encrypt_legacy_artifacts
  for old_set in "$PARQUET_ROOT/sets/"*; do
    [[ -d "$old_set" && "$old_set" != "$encrypted_set" ]] || continue
    "${SUDO[@]}" rm -rf -- "$old_set"
  done
  if [[ -d "$APP_DIR/backend/parquet_cache" ]]; then
    "${SUDO[@]}" rm -rf -- "$APP_DIR/backend/parquet_cache"
  fi
}

pause_guideline_updates() {
  local barrier_result

  "${SUDO[@]}" touch "$ACTIVE_PARQUET_SET/.guideline-settings-paused"
  GUIDELINE_UPDATES_PAUSED=1
  barrier_result="$("${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
    mariadb -N -uroot "$MARIADB_DATABASE" \
    -e "SELECT GET_LOCK('intelvia-guideline-adherence-publish', 600); SELECT RELEASE_LOCK('intelvia-guideline-adherence-publish')")"
  [[ "$barrier_result" == $'1\n1' ]] || {
    echo "Could not establish the guideline publication deployment barrier" >&2
    return 1
  }
}

pause_candidate_guideline_updates() {
  "${SUDO[@]}" touch "$CANDIDATE_PARQUET_SET/.guideline-settings-paused"
}

resume_guideline_updates() {
  "${SUDO[@]}" rm -f "$ACTIVE_PARQUET_SET/.guideline-settings-paused"
  if [[ -n "${CANDIDATE_PARQUET_SET:-}" ]]; then
    "${SUDO[@]}" rm -f "$CANDIDATE_PARQUET_SET/.guideline-settings-paused"
  fi
  [[ ! -e "$ACTIVE_PARQUET_SET/.guideline-settings-paused" \
    && ( -z "${CANDIDATE_PARQUET_SET:-}" \
      || ! -e "$CANDIDATE_PARQUET_SET/.guideline-settings-paused" ) ]] || {
    echo "Guideline update pause marker could not be removed" >&2
    return 1
  }
  GUIDELINE_UPDATES_PAUSED=0
}

reconcile_pending_deployment() {
  [[ -f "$PENDING_FILE" ]] || return 0
  echo "Recovering interrupted deployment from $PENDING_FILE"
  # shellcheck disable=SC1090
  source "$PENDING_FILE"
  if [[ "${PENDING_CUTOVER_COMPLETE:-0}" == "1" ]]; then
    [[ "$STATE_LOADED" == "1" ]] || {
      echo "Cutover-complete deployment journal has no committed state; preserving recovery journal" >&2
      return 1
    }
    CUTOVER_COMPLETE=1
    echo "Completing post-cutover MariaDB account retirement"
    "${COMPOSE[@]}" stop "$(frontend_for_color "$PENDING_ACTIVE_COLOR")" \
      "$(backend_for_color "$PENDING_ACTIVE_COLOR")" >/dev/null 2>&1 || true
    finish_artifact_encryption_upgrade "${PENDING_PREVIOUS_SECURITY_GENERATION:-2}" \
      "$PENDING_SECURITY_GENERATION" "$ACTIVE_PARQUET_SET"
    retire_legacy_database_account
    restore_active_celery_worker
    "${SUDO[@]}" rm -f "$ACTIVE_PARQUET_SET/.guideline-settings-paused" \
      "$PENDING_ACTIVE_PARQUET_SET/.guideline-settings-paused"
    rm -f "$PENDING_FILE"
    echo "Post-cutover deployment recovery complete"
    return
  fi
  if [[ "${DEPLOYMENT_ID:-}" == "$PENDING_TARGET_DEPLOYMENT_ID" ]]; then
    CUTOVER_COMPLETE=1
    "${SUDO[@]}" install -d "$(dirname "$NGINX_UPSTREAM_CONF")" "$(dirname "$NGINX_SITE_CONF")" "$(dirname "$NGINX_SITE_ENABLED")"
    printf 'server 127.0.0.1:%s;\n' "$(port_for_color "$ACTIVE_COLOR")" \
      | "${SUDO[@]}" tee "$NGINX_UPSTREAM_CONF.new" >/dev/null
    "${SUDO[@]}" mv "$NGINX_UPSTREAM_CONF.new" "$NGINX_UPSTREAM_CONF"
    "${SUDO[@]}" install -m 0644 server-nginx.intelvia-app.conf "$NGINX_SITE_CONF"
    "${SUDO[@]}" ln -sfn "$NGINX_SITE_CONF" "$NGINX_SITE_ENABLED"
    "${SUDO[@]}" nginx -t
    "${SUDO[@]}" systemctl reload nginx
    committed_link="$PARQUET_ROOT/.current-recovery"
    ln -sfn "$ACTIVE_PARQUET_SET" "$committed_link"
    mv -Tf "$committed_link" "$PARQUET_ROOT/current"
    "${COMPOSE[@]}" stop "$(frontend_for_color "$(other_color "$ACTIVE_COLOR")")" \
      "$(backend_for_color "$(other_color "$ACTIVE_COLOR")")" >/dev/null 2>&1 || true
    finish_artifact_encryption_upgrade "${PENDING_PREVIOUS_SECURITY_GENERATION:-2}" \
      "$PENDING_SECURITY_GENERATION" "$ACTIVE_PARQUET_SET"
    retire_legacy_database_account
    restore_active_celery_worker
    "${SUDO[@]}" rm -f "$ACTIVE_PARQUET_SET/.guideline-settings-paused" \
      "$PENDING_ACTIVE_PARQUET_SET/.guideline-settings-paused"
    rm -f "$PENDING_FILE"
    NGINX_ACTIVE_COLOR="$ACTIVE_COLOR"
    echo "Interrupted deployment had already committed; reconciled to $ACTIVE_COLOR"
    return
  fi
  "${SUDO[@]}" install -d "$(dirname "$NGINX_UPSTREAM_CONF")" "$(dirname "$NGINX_SITE_CONF")" "$(dirname "$NGINX_SITE_ENABLED")"
  "${COMPOSE[@]}" stop celery-worker >/dev/null 2>&1 || true
  restore_legacy_database_transport
  if [[ -n "${PENDING_GUIDELINE_CONFIG_VERSION:-}" ]]; then
    "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py restore_guideline_publication \
      --expected-version "$PENDING_GUIDELINE_CONFIG_VERSION" \
      --published-version "$PENDING_GUIDELINE_PREVIOUS_PUBLISHED_VERSION" \
      --cache-version "$PENDING_GUIDELINE_PREVIOUS_CACHE_VERSION" \
      --status "$PENDING_GUIDELINE_PREVIOUS_STATUS" \
      --strict
  fi
  printf 'server 127.0.0.1:%s;\n' "$(port_for_color "$PENDING_ACTIVE_COLOR")" \
    | "${SUDO[@]}" tee "$NGINX_UPSTREAM_CONF.new" >/dev/null
  "${SUDO[@]}" mv "$NGINX_UPSTREAM_CONF.new" "$NGINX_UPSTREAM_CONF"
  "${SUDO[@]}" install -m 0644 server-nginx.intelvia-app.conf "$NGINX_SITE_CONF"
  "${SUDO[@]}" ln -sfn "$NGINX_SITE_CONF" "$NGINX_SITE_ENABLED"
  "${SUDO[@]}" nginx -t
  "${SUDO[@]}" systemctl reload nginx
  if [[ -n "$PENDING_ACTIVE_PARQUET_SET" ]]; then
    recovery_link="$PARQUET_ROOT/.current-recovery"
    ln -sfn "$PENDING_ACTIVE_PARQUET_SET" "$recovery_link"
    mv -Tf "$recovery_link" "$PARQUET_ROOT/current"
  fi
  "${COMPOSE[@]}" stop "$(frontend_for_color "$PENDING_NEXT_COLOR")" "$(backend_for_color "$PENDING_NEXT_COLOR")" >/dev/null 2>&1 || true
  DERIVED_MUTATED="$PENDING_DERIVED_MUTATED"
  DERIVED_BACKUP="$PENDING_DERIVED_BACKUP"
  DERIVED_ORIGINAL_STATE="$PENDING_DERIVED_ORIGINAL_STATE"
  DERIVED_ORIGINAL_TABLES="${PENDING_DERIVED_ORIGINAL_TABLES:-}"
  restore_derived_tables
  restore_active_celery_worker
  if [[ -n "$PENDING_NEW_PARQUET_PATH" && "$PENDING_NEW_PARQUET_PATH" != "$PENDING_ACTIVE_PARQUET_SET" \
    && ( "$PENDING_NEW_PARQUET_PATH" == "$PARQUET_ROOT/.staging/"* || "$PENDING_NEW_PARQUET_PATH" == "$PARQUET_ROOT/sets/"* ) ]]; then
    "${SUDO[@]}" rm -rf -- "$PENDING_NEW_PARQUET_PATH" || true
  fi
  if [[ "$PENDING_MIGRATION_CHANGES" == "true" && "$PENDING_MIGRATION_ATTEMPTED" == "1" && -f "$STATE_DIR/current.env" ]]; then
    sed -i.bak -e '/^MIGRATION_CHANGES=/d' -e '/^SCHEMA_GENERATION=/d' "$STATE_DIR/current.env"
    printf 'MIGRATION_CHANGES=true\nSCHEMA_GENERATION=%q\n' "$PENDING_SCHEMA_GENERATION" >> "$STATE_DIR/current.env"
    rm -f "$STATE_DIR/current.env.bak"
  fi
  "${SUDO[@]}" rm -f "$PENDING_ACTIVE_PARQUET_SET/.guideline-settings-paused"
  if [[ -n "$PENDING_NEW_PARQUET_PATH" ]]; then
    "${SUDO[@]}" rm -f "$PENDING_NEW_PARQUET_PATH/.guideline-settings-paused"
  fi
  if [[ "$DERIVED_RESTORE_FAILED" != "1" ]]; then
    rm -f "$PENDING_FILE"
  else
    echo "Derived-table restoration failed; preserving pending recovery journal" >&2
    return 1
  fi
  DERIVED_MUTATED=0
  NGINX_ACTIVE_COLOR="$PENDING_ACTIVE_COLOR"
  echo "Interrupted deployment reconciled to $PENDING_ACTIVE_COLOR"
}

cleanup_failed_deployment() {
  local status="$1"
  local restore_failed=0
  if [[ "$CUTOVER_COMPLETE" == "0" ]]; then
    "${COMPOSE[@]}" stop celery-worker >/dev/null 2>&1 || true
    if ! restore_legacy_database_transport; then
      echo "Could not restore legacy-compatible database transport; preserving the candidate route and pending recovery journal" >&2
      return
    fi
    if [[ -n "${GUIDELINE_CONFIG_VERSION:-}" ]]; then
      if ! "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py restore_guideline_publication \
        --expected-version "$GUIDELINE_CONFIG_VERSION" \
        --published-version "$GUIDELINE_PREVIOUS_PUBLISHED_VERSION" \
        --cache-version "$GUIDELINE_PREVIOUS_CACHE_VERSION" \
        --status "$GUIDELINE_PREVIOUS_STATUS" \
        --strict; then
        restore_failed=1
        echo "Guideline publication recovery failed; preserving $PENDING_FILE for retry" >&2
      fi
    fi
    restore_nginx_config
    if [[ "$POINTER_CHANGED" == "1" && -n "$ACTIVE_PARQUET_SET" ]]; then
      rollback_link="$PARQUET_ROOT/.current-error-rollback"
      ln -sfn "$ACTIVE_PARQUET_SET" "$rollback_link" || true
      mv -Tf "$rollback_link" "$PARQUET_ROOT/current" || true
    fi
    "${COMPOSE[@]}" stop "$(frontend_for_color "$NEXT_COLOR")" "$(backend_for_color "$NEXT_COLOR")" >/dev/null 2>&1 || true
    if ! restore_derived_tables; then
      restore_failed=1
      echo "Derived-table recovery failed; preserving $PENDING_FILE for retry" >&2
    elif ! restore_active_celery_worker; then
      restore_failed=1
      echo "Could not restore the active guideline worker; preserving $PENDING_FILE for retry" >&2
    fi
    if [[ "$restore_failed" == "0" && -n "$NEW_PARQUET_PATH" && "$NEW_PARQUET_PATH" != "$ACTIVE_PARQUET_SET" \
      && ( "$NEW_PARQUET_PATH" == "$PARQUET_ROOT/.staging/"* || "$NEW_PARQUET_PATH" == "$PARQUET_ROOT/sets/"* ) ]]; then
      "${SUDO[@]}" rm -rf -- "$NEW_PARQUET_PATH" || true
    fi
    {
      printf 'FAILED_AT=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'IMAGE_TAG=%q\n' "$IMAGE_TAG"
      printf 'SOURCE_COMMIT=%q\n' "$SOURCE_COMMIT"
      printf 'EXIT_STATUS=%q\n' "$status"
    } > "$STATE_DIR/history/failed-$timestamp-$IMAGE_TAG.env" || true
    if [[ "$MIGRATION_CHANGES" == "true" && "$MIGRATION_ATTEMPTED" == "1" && -f "$STATE_DIR/current.env" ]]; then
      sed -i.bak -e '/^MIGRATION_CHANGES=/d' -e '/^SCHEMA_GENERATION=/d' "$STATE_DIR/current.env" || true
      printf 'MIGRATION_CHANGES=true\nSCHEMA_GENERATION=%q\n' "$CANDIDATE_SCHEMA_GENERATION" >> "$STATE_DIR/current.env" || true
      rm -f "$STATE_DIR/current.env.bak" || true
    fi
    if [[ "$restore_failed" == "0" ]]; then
      if ! resume_guideline_updates; then
        restore_failed=1
        echo "Guideline updates remain paused; preserving $PENDING_FILE for retry" >&2
      fi
    fi
  fi
  "${SUDO[@]}" rm -rf "$NGINX_BACKUP_DIR" >/dev/null 2>&1 || true
  if [[ "$CUTOVER_COMPLETE" == "1" || "$DERIVED_RESTORE_FAILED" == "1" || "$restore_failed" != "0" ]]; then
    echo "Deployment cutover or recovery is incomplete; preserving pending recovery journal" >&2
  else
    rm -f "$PENDING_FILE"
  fi
  echo "Deployment failed; active nginx and parquet pointers were preserved or restored" >&2
  [[ "$restore_failed" == "0" ]]
}

on_exit() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ "$status" != "0" ]]; then
    if ! cleanup_failed_deployment "$status"; then
      status=1
    fi
  fi
  exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

reconcile_pending_deployment
if [[ "$RECOVER_ONLY" == "1" ]]; then
  echo "Deployment recovery complete"
  exit 0
fi
CUTOVER_COMPLETE=0
LEGACY_RETIREMENT_COMPLETE=0
if [[ "$STATE_LOADED" == "1" && -n "$NGINX_ACTIVE_COLOR" && "$NGINX_ACTIVE_COLOR" != "$ACTIVE_COLOR" ]]; then
  echo "Deployment state says $ACTIVE_COLOR but nginx routes to $NGINX_ACTIVE_COLOR after recovery" >&2
  exit 1
fi
write_pending_state

echo "Pulling immutable images for $IMAGE_TAG"
"${COMPOSE[@]}" pull backend-tool "$(backend_for_color "$NEXT_COLOR")" "$(frontend_for_color "$NEXT_COLOR")"
echo "Starting MariaDB and waiting for it to become healthy"
"${COMPOSE[@]}" up -d --wait --wait-timeout "$HEALTH_TIMEOUT" mariadb
echo "Reconciling least-privilege MariaDB accounts"
"${COMPOSE[@]}" run --rm mariadb-provision
echo "Verifying MariaDB audit, TLS, and at-rest encryption safeguards"
"${COMPOSE[@]}" run --rm mariadb-security-check
export TOOL_PARQUET_SET_PATH="$ACTIVE_PARQUET_SET"
if (( SECURITY_GENERATION >= 2 )) && {
  [[ -f "$ACTIVE_PARQUET_SET/current/visit_attributes.parquet" ]] ||
    [[ -f "$ACTIVE_PARQUET_SET/visit_attributes.parquet" ]]
}; then
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py shell -c \
    "from api.artifact_encryption import encrypted_reader; from api.artifacts import active_artifact_dir, cache_dir; encrypted_reader(active_artifact_dir(cache_dir()) / 'visit_attributes.parquet').close()" || {
    echo "The configured artifact key cannot read the active clinical data" >&2
    exit 1
  }
fi

pause_guideline_updates
write_pending_state

if [[ "$PREPARE_DATA" == "true" ]]; then
  active_set_bytes="$("${SUDO[@]}" du -sb "$ACTIVE_PARQUET_SET" 2>/dev/null | awk '{print $1}')"
  active_set_bytes="${active_set_bytes:-0}"
  available_bytes="$(df -PB1 "$PARQUET_ROOT" | awk 'NR == 2 {print $4}')"
  required_bytes=$((active_set_bytes + MIN_PARQUET_FREE_BYTES))
  if (( available_bytes < required_bytes )); then
    echo "Insufficient parquet storage: available=$available_bytes required=$required_bytes" >&2
    exit 1
  fi
  backup_tmp="$APP_DIR/backups/.predeploy-$timestamp.sql.enc.tmp"
  echo "Writing encrypted pre-deployment database backup"
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
    mariadb-dump -uroot --single-transaction --quick "$MARIADB_DATABASE" |
    encrypt_database_backup "$backup_tmp"
  publish_retained_backup daily
  week="$(date -u +%G-W%V)"
  month="$(date -u +%Y-%m)"
  if [[ "$(cat "$APP_DIR/backups/.weekly-marker" 2>/dev/null || true)" != "$week" ]] \
    || ! has_retained_backup weekly; then
    publish_retained_backup weekly
    printf '%s\n' "$week" > "$APP_DIR/backups/.weekly-marker"
  fi
  if [[ "$(cat "$APP_DIR/backups/.monthly-marker" 2>/dev/null || true)" != "$month" ]] \
    || ! has_retained_backup monthly; then
    publish_retained_backup monthly
    printf '%s\n' "$month" > "$APP_DIR/backups/.monthly-marker"
  fi
  rm -f "$backup_tmp"
  rm -f "$backup_tmp.hmac"
fi

echo "Applying Django migrations once"
export TOOL_PARQUET_SET_PATH="$ACTIVE_PARQUET_SET"
MIGRATION_ATTEMPTED=1
write_pending_state
"${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py migrate --noinput
echo "Finalizing runtime grants after migrations"
"${COMPOSE[@]}" run --rm mariadb-provision
"${COMPOSE[@]}" run --rm mariadb-security-check

if [[ -n "$ROLLBACK_STATE" ]]; then
  publication_state="$("${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py guideline_publication_state)"
  IFS='|' read -r GUIDELINE_CONFIG_VERSION GUIDELINE_PREVIOUS_PUBLISHED_VERSION \
    GUIDELINE_PREVIOUS_CACHE_VERSION GUIDELINE_PREVIOUS_STATUS <<< "$publication_state"
  export TOOL_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"
  target_publication_state="$("${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py guideline_publication_state --from-parquet)"
  IFS='|' read -r _target_guideline_version GUIDELINE_TARGET_PUBLISHED_VERSION \
    GUIDELINE_TARGET_CACHE_VERSION GUIDELINE_TARGET_STATUS <<< "$target_publication_state"
  [[ "$GUIDELINE_TARGET_PUBLISHED_VERSION" =~ ^[0-9]+$ && -n "$GUIDELINE_TARGET_CACHE_VERSION" \
    && "$GUIDELINE_TARGET_STATUS" == "complete" ]] || {
    echo "Rollback parquet set has no valid guideline publication state" >&2
    exit 1
  }
  [[ "$GUIDELINE_TARGET_PUBLISHED_VERSION" == "$GUIDELINE_CONFIG_VERSION" ]] || {
    echo "Rollback is blocked because its guideline version differs from the current configuration" >&2
    exit 1
  }
  copy_guideline_overlay_generation \
    "$CANDIDATE_PARQUET_SET" \
    "$CANDIDATE_PARQUET_SET" \
    "$GUIDELINE_TARGET_CACHE_VERSION"
  copy_guideline_overlay_generation \
    "$ACTIVE_PARQUET_SET" \
    "$CANDIDATE_PARQUET_SET" \
    "$GUIDELINE_PREVIOUS_CACHE_VERSION"
  pause_candidate_guideline_updates
  if [[ "${ROLLBACK_RESTORES_DERIVED:-0}" == "1" ]]; then
    DERIVED_BACKUP="$APP_DIR/backups/derived-$timestamp.sql.enc"
    backup_derived_tables "$DERIVED_BACKUP"
    DERIVED_MUTATED=1
  fi
  write_pending_state
fi

if [[ "$PREPARE_DATA" == "true" ]]; then
  [[ "$CANDIDATE_PARQUET_SET" == "$PARQUET_ROOT/.staging/"* ]] || {
    echo "Refusing to prepare data outside the parquet staging root" >&2
    exit 1
  }
  "${SUDO[@]}" rm -rf "$CANDIDATE_PARQUET_SET"
  mkdir -p "$CANDIDATE_PARQUET_SET"
  pause_candidate_guideline_updates
  DERIVED_BACKUP="$APP_DIR/backups/derived-$timestamp.sql.enc"
  backup_derived_tables "$DERIVED_BACKUP"
  DERIVED_MUTATED=1
  NEW_PARQUET_PATH="$CANDIDATE_PARQUET_SET"
  export TOOL_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"
  GUIDELINE_CONFIG_VERSION="$("${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py guideline_config_version)"
  publication_state="$("${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py guideline_publication_state)"
  IFS='|' read -r _current_guideline_version GUIDELINE_PREVIOUS_PUBLISHED_VERSION \
    GUIDELINE_PREVIOUS_CACHE_VERSION GUIDELINE_PREVIOUS_STATUS <<< "$publication_state"
  write_pending_state
  if [[ -n "$MOCK_DATA_SIZE" ]]; then
    "${COMPOSE[@]}" run --rm -e MARIADB_ALLOW_LOCAL_INFILE=true backend-tool \
      poetry run python manage.py refresh_demo_data --size "$MOCK_DATA_SIZE"
  fi
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py prepare_parquet_set \
    --guideline-version "$GUIDELINE_CONFIG_VERSION"
  copy_guideline_overlay_generation \
    "$ACTIVE_PARQUET_SET" \
    "$CANDIDATE_PARQUET_SET" \
    "$GUIDELINE_PREVIOUS_CACHE_VERSION"
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py encrypt_legacy_artifacts --only-root
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py validate_parquets \
    --image-tag "$IMAGE_TAG" --source-commit "$SOURCE_COMMIT" --write-manifest
  "${SUDO[@]}" chown -R "$(id -u):$(id -g)" "$CANDIDATE_PARQUET_SET"
  chmod -R u+rwX,go-rwx "$CANDIDATE_PARQUET_SET"
elif [[ -z "$ROLLBACK_STATE" ]]; then
  publication_state="$("${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py guideline_publication_state)"
  IFS='|' read -r _current_guideline_version _current_published_version \
    current_cache_version _current_status <<< "$publication_state"
  copy_guideline_overlay_generation \
    "$CANDIDATE_PARQUET_SET" \
    "$CANDIDATE_PARQUET_SET" \
    "$current_cache_version"
fi

echo "Starting inactive $NEXT_COLOR application pair"
"${COMPOSE[@]}" stop "$(frontend_for_color "$NEXT_COLOR")" "$(backend_for_color "$NEXT_COLOR")" >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --force-recreate "$(backend_for_color "$NEXT_COLOR")" "$(frontend_for_color "$NEXT_COLOR")"

deadline=$((SECONDS + HEALTH_TIMEOUT))
until smoke_candidate_frontend "http://127.0.0.1:$NEXT_PORT" \
  && smoke_auth "http://127.0.0.1:$NEXT_PORT" \
  && curl -fsS --max-time 4 -H 'Host: intelvia.app' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$NEXT_PORT/health/" >/dev/null \
  && curl -fsS --max-time 8 -H 'Host: intelvia.app' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$NEXT_PORT/api/health/" >/dev/null; do
  (( SECONDS < deadline )) || { echo "Candidate health check timed out" >&2; false; }
  sleep 3
done

if [[ "${ROLLBACK_RESTORES_DERIVED:-0}" == "1" ]]; then
  restore_derived_snapshot \
    "$ROLLBACK_DERIVED_ORIGINAL_STATE" \
    "$ROLLBACK_DERIVED_BACKUP" \
    "$ROLLBACK_DERIVED_TABLES"
fi

if [[ "$PREPARE_DATA" == "true" ]]; then
  promoted_set="$PARQUET_ROOT/sets/$PARQUET_SET_ID"
  mv "$CANDIDATE_PARQUET_SET" "$promoted_set"
  CANDIDATE_PARQUET_SET="$promoted_set"
  NEW_PARQUET_PATH="$promoted_set"
  export TOOL_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"
  write_pending_state
fi
export WORKER_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"
"${COMPOSE[@]}" up -d --force-recreate celery-worker

OLD_UPSTREAM="$(cat "$NGINX_UPSTREAM_CONF" 2>/dev/null || printf 'server 127.0.0.1:%s;\n' "$ACTIVE_PORT")"
"${SUDO[@]}" install -d "$(dirname "$NGINX_UPSTREAM_CONF")" "$(dirname "$NGINX_SITE_CONF")" "$(dirname "$NGINX_SITE_ENABLED")"
install -d -m 0700 "$NGINX_BACKUP_DIR"
if "${SUDO[@]}" test -e "$NGINX_SITE_CONF" || "${SUDO[@]}" test -L "$NGINX_SITE_CONF"; then
  "${SUDO[@]}" cp -a "$NGINX_SITE_CONF" "$NGINX_BACKUP_DIR/site.conf"
fi
if "${SUDO[@]}" test -e "$NGINX_SITE_ENABLED" || "${SUDO[@]}" test -L "$NGINX_SITE_ENABLED"; then
  "${SUDO[@]}" cp -a "$NGINX_SITE_ENABLED" "$NGINX_BACKUP_DIR/site.enabled"
fi
SITE_CONFIG_CHANGED=1
printf 'server 127.0.0.1:%s;\n' "$NEXT_PORT" | "${SUDO[@]}" tee "$NGINX_UPSTREAM_CONF.new" >/dev/null
"${SUDO[@]}" mv "$NGINX_UPSTREAM_CONF.new" "$NGINX_UPSTREAM_CONF"
UPSTREAM_CHANGED=1
"${SUDO[@]}" install -m 0644 server-nginx.intelvia-app.conf "$NGINX_SITE_CONF.new"
"${SUDO[@]}" mv "$NGINX_SITE_CONF.new" "$NGINX_SITE_CONF"
"${SUDO[@]}" ln -sfn "$NGINX_SITE_CONF" "$NGINX_SITE_ENABLED"
"${SUDO[@]}" nginx -t
"${SUDO[@]}" systemctl reload nginx

if [[ "$TRANSITIONAL_TLS_UPGRADE" == "1" ]]; then
  echo "Enforcing MariaDB TLS after cutting traffic to the TLS-capable candidate"
  MARIADB_REQUIRE_SECURE_TRANSPORT=ON
  export MARIADB_REQUIRE_SECURE_TRANSPORT
  "${COMPOSE[@]}" up -d --force-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" mariadb
  "${COMPOSE[@]}" run --rm mariadb-provision
  "${COMPOSE[@]}" run --rm mariadb-security-check
fi

current_link_tmp="$PARQUET_ROOT/.current-$timestamp"
ln -s "$CANDIDATE_PARQUET_SET" "$current_link_tmp"
mv -Tf "$current_link_tmp" "$PARQUET_ROOT/current"
POINTER_CHANGED=1

if ! curl -fsS --max-time 15 "$PUBLIC_BASE_URL/health/" >/dev/null \
  || ! curl -fsS --max-time 20 "$PUBLIC_BASE_URL/api/health/" >/dev/null \
  || ! smoke_auth "$PUBLIC_BASE_URL"; then
  false
fi
if [[ "$PREPARE_DATA" == "true" ]]; then
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py commit_guideline_overlay \
    --guideline-version "$GUIDELINE_CONFIG_VERSION"
elif [[ -n "$ROLLBACK_STATE" ]]; then
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py restore_guideline_publication \
    --expected-version "$GUIDELINE_CONFIG_VERSION" \
    --published-version "$GUIDELINE_TARGET_PUBLISHED_VERSION" \
    --cache-version "$GUIDELINE_TARGET_CACHE_VERSION" \
    --status "$GUIDELINE_TARGET_STATUS" \
    --strict
fi
publication_state="$("${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py guideline_publication_state)"
IFS='|' read -r GUIDELINE_CONFIG_VERSION GUIDELINE_PUBLISHED_VERSION \
  GUIDELINE_CACHE_VERSION GUIDELINE_STATUS <<< "$publication_state"
[[ "$GUIDELINE_PUBLISHED_VERSION" =~ ^[0-9]+$ \
  && "$GUIDELINE_CACHE_VERSION" != "" \
  && "$GUIDELINE_STATUS" == "complete" ]] || {
  echo "Guideline publication did not commit successfully" >&2
  false
}
if [[ "$PREPARE_DATA" == "true" ]]; then
  [[ "$GUIDELINE_PUBLISHED_VERSION" == "$GUIDELINE_CONFIG_VERSION" ]] || {
    echo "Guideline publication version does not match the prepared configuration" >&2
    false
  }
elif [[ -n "$ROLLBACK_STATE" ]]; then
  [[ "$GUIDELINE_PUBLISHED_VERSION" == "$GUIDELINE_TARGET_PUBLISHED_VERSION" \
    && "$GUIDELINE_CACHE_VERSION" == "$GUIDELINE_TARGET_CACHE_VERSION" ]] || {
    echo "Guideline publication does not match the rollback target" >&2
    false
  }
fi
copy_guideline_overlay_generation \
  "$CANDIDATE_PARQUET_SET" \
  "$CANDIDATE_PARQUET_SET" \
  "$GUIDELINE_CACHE_VERSION"
resume_guideline_updates
deployment_id="$timestamp-$IMAGE_TAG"
state_file="$STATE_DIR/history/$deployment_id.env"
{
  printf 'ACTIVE_COLOR=%q\n' "$NEXT_COLOR"
  printf 'ACTIVE_IMAGE_TAG=%q\n' "$IMAGE_TAG"
  printf 'ACTIVE_SOURCE_COMMIT=%q\n' "$SOURCE_COMMIT"
  printf 'ACTIVE_PARQUET_SET=%q\n' "$CANDIDATE_PARQUET_SET"
  printf 'ACTIVE_BACKEND_IMAGE=%q\n' "$BACKEND_IMAGE"
  printf 'ACTIVE_FRONTEND_IMAGE=%q\n' "$FRONTEND_IMAGE"
  printf 'PREVIOUS_COLOR=%q\n' "$ACTIVE_COLOR"
  printf 'PREVIOUS_IMAGE_TAG=%q\n' "$ACTIVE_IMAGE_TAG"
  printf 'PREVIOUS_SOURCE_COMMIT=%q\n' "$ACTIVE_SOURCE_COMMIT"
  printf 'PREVIOUS_PARQUET_SET=%q\n' "$ACTIVE_PARQUET_SET"
  printf 'DATA_PREPARED=%q\n' "$PREPARE_DATA"
  printf 'MIGRATION_CHANGES=%q\n' "$MIGRATION_CHANGES"
  printf 'SCHEMA_GENERATION=%q\n' "$CANDIDATE_SCHEMA_GENERATION"
  printf 'SECURITY_GENERATION=%q\n' "$CANDIDATE_SECURITY_GENERATION"
  printf 'DEPLOY_PACKAGE_COMMIT=%q\n' "$DEPLOY_PACKAGE_COMMIT"
  printf 'GUIDELINE_CONFIG_VERSION=%q\n' "$GUIDELINE_CONFIG_VERSION"
  printf 'GUIDELINE_PUBLISHED_VERSION=%q\n' "$GUIDELINE_PUBLISHED_VERSION"
  printf 'GUIDELINE_CACHE_VERSION=%q\n' "$GUIDELINE_CACHE_VERSION"
  printf 'GUIDELINE_STATUS=%q\n' "$GUIDELINE_STATUS"
  printf 'DERIVED_ROLLBACK_BACKUP=%q\n' "$DERIVED_BACKUP"
  printf 'DERIVED_ROLLBACK_ORIGINAL_STATE=%q\n' "$DERIVED_ORIGINAL_STATE"
  printf 'DERIVED_ROLLBACK_TABLES=%q\n' "$DERIVED_ORIGINAL_TABLES"
  printf 'DEPLOYED_AT=%q\n' "$timestamp"
  printf 'DEPLOYMENT_ID=%q\n' "$deployment_id"
} > "$state_file"
cp "$state_file" "$STATE_DIR/current.env"
CUTOVER_COMPLETE=1
write_pending_state
DERIVED_MUTATED=0
NEW_PARQUET_PATH=""

"${COMPOSE[@]}" stop "$(frontend_for_color "$ACTIVE_COLOR")" "$(backend_for_color "$ACTIVE_COLOR")" >/dev/null 2>&1 || true
export TOOL_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"
finish_artifact_encryption_upgrade "$SECURITY_GENERATION" "$CANDIDATE_SECURITY_GENERATION" \
  "$CANDIDATE_PARQUET_SET"
retire_legacy_database_account
rm -f "$PENDING_FILE"
if ! "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py prune_scoped_artifacts; then
  echo "Could not prune old scoped artifacts; deployment remains active" >&2
fi
"${SUDO[@]}" rm -rf "$NGINX_BACKUP_DIR" || true
mapfile -t successful_history < <(ls -1t "$STATE_DIR/history"/20*.env 2>/dev/null || true)
for ((history_index = ROLLBACK_RETENTION_COUNT; history_index < ${#successful_history[@]}; history_index += 1)); do
  stale_state="${successful_history[$history_index]}"
  stale_derived_backup="$(
    unset DERIVED_ROLLBACK_BACKUP
    # shellcheck disable=SC1090
    source "$stale_state"
    printf '%s' "${DERIVED_ROLLBACK_BACKUP:-}"
  )"
  rm -f -- "$stale_state"
  if [[ "$stale_derived_backup" == "$APP_DIR/backups/derived-"*.sql.enc \
    && -f "$stale_derived_backup" ]] \
    && ! rg -F -q -- "$stale_derived_backup" "$STATE_DIR/current.env" "$STATE_DIR/history" 2>/dev/null \
    && ! grep -F -R -q -- "$stale_derived_backup" "$STATE_DIR/current.env" "$STATE_DIR/history" 2>/dev/null; then
    rm -f -- "$stale_derived_backup" "$stale_derived_backup.hmac"
  fi
done
for stale_staging in "$PARQUET_ROOT/.staging/"*; do
  [[ -e "$stale_staging" ]] || continue
  "${SUDO[@]}" rm -rf -- "$stale_staging" || true
done
for parquet_set in "$PARQUET_ROOT/sets/"*; do
  [[ -d "$parquet_set" ]] || continue
  if [[ "$parquet_set" == "$CANDIDATE_PARQUET_SET" || "$parquet_set" == "$ACTIVE_PARQUET_SET" ]]; then
    continue
  fi
  if rg -F -q -- "$parquet_set" "$STATE_DIR/current.env" "$STATE_DIR/history" 2>/dev/null \
    || grep -F -R -q -- "$parquet_set" "$STATE_DIR/current.env" "$STATE_DIR/history" 2>/dev/null; then
    continue
  fi
  "${SUDO[@]}" rm -rf -- "$parquet_set" || true
done
docker image prune -a -f --filter "until=${IMAGE_PRUNE_AGE:-168h}" || true
echo "Deployment complete: id=$deployment_id color=$NEXT_COLOR image=$IMAGE_TAG parquets=$CANDIDATE_PARQUET_SET prepared=$PREPARE_DATA"
