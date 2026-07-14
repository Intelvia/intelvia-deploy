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
STATE_DIR="${STATE_DIR:-$APP_DIR/.deploy-state}"
PARQUET_ROOT="${PARQUET_ROOT:-/srv/intelvia/parquets}"
NGINX_SITE_CONF="${NGINX_SITE_CONF:-/etc/nginx/sites-available/intelvia.app}"
NGINX_SITE_ENABLED="${NGINX_SITE_ENABLED:-/etc/nginx/sites-enabled/intelvia.app}"
NGINX_UPSTREAM_CONF="${NGINX_UPSTREAM_CONF:-/etc/nginx/snippets/intelvia-active-upstream.conf}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://intelvia.app}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
COMPOSE=(docker compose -p intelvia -f docker-compose.intelvia-app.yml --profile tools)
SUDO=()

IMAGE_TAG=""
SOURCE_COMMIT=""
DATA_PREPARATION_MODE="auto"
DATA_CHANGES="false"
ROLLBACK_STATE=""
DERIVED_MUTATED=0
DERIVED_BACKUP=""
DERIVED_ORIGINAL_STATE="unknown"
CUTOVER_COMPLETE=0
UPSTREAM_CHANGED=0
POINTER_CHANGED=0
SITE_CONFIG_CHANGED=0
OLD_UPSTREAM=""
NEW_PARQUET_PATH=""

usage() {
  echo "Usage: $0 --image-tag TAG --source-commit SHA [--mode auto|force|reuse] [--data-changes true|false]" >&2
  echo "       $0 --rollback-state DEPLOYMENT_ID" >&2
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --image-tag) IMAGE_TAG="$2"; shift 2 ;;
    --source-commit) SOURCE_COMMIT="$2"; shift 2 ;;
    --mode) DATA_PREPARATION_MODE="$2"; shift 2 ;;
    --data-changes) DATA_CHANGES="$2"; shift 2 ;;
    --rollback-state) ROLLBACK_STATE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

cd "$APP_DIR"
mkdir -p "$STATE_DIR/history" "$PARQUET_ROOT/.staging" "$PARQUET_ROOT/sets" "$APP_DIR/backups"
exec 9>"$STATE_DIR/deploy.lock"
flock -n 9 || { echo "Another Intelvia deployment is running" >&2; exit 1; }

if [[ "${DEPLOY_USE_SUDO:-1}" != "0" && "$(id -u)" != "0" ]]; then
  SUDO=(sudo)
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
else
  echo "$APP_DIR/.env is required" >&2
  exit 1
fi

ACTIVE_COLOR="blue"
ACTIVE_IMAGE_TAG=""
ACTIVE_SOURCE_COMMIT="unknown"
ACTIVE_PARQUET_SET=""
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

NGINX_ACTIVE_COLOR=""
if [[ -f "$NGINX_UPSTREAM_CONF" ]]; then
  if rg -q '127\.0\.0\.1:8081' "$NGINX_UPSTREAM_CONF" 2>/dev/null || grep -q '127\.0\.0\.1:8081' "$NGINX_UPSTREAM_CONF"; then
    NGINX_ACTIVE_COLOR="green"
  elif rg -q '127\.0\.0\.1:8080' "$NGINX_UPSTREAM_CONF" 2>/dev/null || grep -q '127\.0\.0\.1:8080' "$NGINX_UPSTREAM_CONF"; then
    NGINX_ACTIVE_COLOR="blue"
  fi
fi
if [[ "$STATE_LOADED" == "1" && -n "$NGINX_ACTIVE_COLOR" && "$NGINX_ACTIVE_COLOR" != "$ACTIVE_COLOR" ]]; then
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
  # shellcheck disable=SC1090
  source "$rollback_file"
  TARGET_IMAGE_TAG="$ACTIVE_IMAGE_TAG"
  TARGET_SOURCE_COMMIT="$ACTIVE_SOURCE_COMMIT"
  TARGET_PARQUET_SET="$ACTIVE_PARQUET_SET"
  ACTIVE_COLOR="$CURRENT_ACTIVE_COLOR"
  ACTIVE_IMAGE_TAG="$CURRENT_ACTIVE_IMAGE_TAG"
  ACTIVE_SOURCE_COMMIT="$CURRENT_ACTIVE_SOURCE_COMMIT"
  ACTIVE_PARQUET_SET="$CURRENT_ACTIVE_PARQUET_SET"
  IMAGE_TAG="$TARGET_IMAGE_TAG"
  SOURCE_COMMIT="$TARGET_SOURCE_COMMIT"
  ROLLBACK_PARQUET_SET="$TARGET_PARQUET_SET"
  DATA_PREPARATION_MODE="reuse"
fi

[[ "$IMAGE_TAG" =~ ^sha-[0-9a-f]{40}$ || "$IMAGE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Image tag must be an immutable sha-* or semantic version tag" >&2
  exit 1
}
[[ -n "$SOURCE_COMMIT" ]] || usage
[[ "$DATA_PREPARATION_MODE" =~ ^(auto|force|reuse)$ ]] || usage
[[ "$DATA_CHANGES" =~ ^(true|false)$ ]] || usage

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

if [[ "$DATA_PREPARATION_MODE" == "reuse" && -n "${ROLLBACK_PARQUET_SET:-}" ]]; then
  CANDIDATE_PARQUET_SET="$ROLLBACK_PARQUET_SET"
elif [[ "$PREPARE_DATA" == "true" ]]; then
  CANDIDATE_PARQUET_SET="$PARQUET_ROOT/.staging/$PARQUET_SET_ID"
else
  CANDIDATE_PARQUET_SET="$ACTIVE_PARQUET_SET"
fi

export COMPOSE_PROJECT_NAME=intelvia INTELVIA_IMAGE_TAG="$IMAGE_TAG" INTELVIA_SOURCE_COMMIT="$SOURCE_COMMIT"
export BLUE_PARQUET_SET_PATH="$ACTIVE_PARQUET_SET" GREEN_PARQUET_SET_PATH="$ACTIVE_PARQUET_SET"
if [[ "$NEXT_COLOR" == "blue" ]]; then
  BLUE_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"
else
  GREEN_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"
fi
export BLUE_PARQUET_SET_PATH GREEN_PARQUET_SET_PATH

restore_derived_tables() {
  if [[ "$DERIVED_MUTATED" != "1" ]]; then
    return
  fi
  if [[ "$DERIVED_ORIGINAL_STATE" == "three" && -s "$DERIVED_BACKUP" ]]; then
      echo "Restoring pre-deployment derived tables"
      "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
        mariadb -uroot "$MARIADB_DATABASE" < "$DERIVED_BACKUP" || true
  elif [[ "$DERIVED_ORIGINAL_STATE" == "zero" ]]; then
      echo "Removing derived tables created by the failed deployment"
      "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
        mariadb -uroot "$MARIADB_DATABASE" \
        -e 'DROP TABLE IF EXISTS GuidelineAdherence, VisitAttributes, SurgeryCaseAttributes' || true
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

on_error() {
  status=$?
  if [[ "$CUTOVER_COMPLETE" == "0" ]]; then
    restore_nginx_config
    if [[ "$POINTER_CHANGED" == "1" && -n "$ACTIVE_PARQUET_SET" ]]; then
      rollback_link="$PARQUET_ROOT/.current-error-rollback"
      ln -sfn "$ACTIVE_PARQUET_SET" "$rollback_link" || true
      mv -Tf "$rollback_link" "$PARQUET_ROOT/current" || true
    fi
    "${COMPOSE[@]}" stop "$(frontend_for_color "$NEXT_COLOR")" "$(backend_for_color "$NEXT_COLOR")" >/dev/null 2>&1 || true
    restore_derived_tables
    if [[ -n "$NEW_PARQUET_PATH" && "$NEW_PARQUET_PATH" != "$ACTIVE_PARQUET_SET" \
      && ( "$NEW_PARQUET_PATH" == "$PARQUET_ROOT/.staging/"* || "$NEW_PARQUET_PATH" == "$PARQUET_ROOT/sets/"* ) ]]; then
      rm -rf -- "$NEW_PARQUET_PATH" || true
    fi
    {
      printf 'FAILED_AT=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'IMAGE_TAG=%q\n' "$IMAGE_TAG"
      printf 'SOURCE_COMMIT=%q\n' "$SOURCE_COMMIT"
      printf 'EXIT_STATUS=%q\n' "$status"
    } > "$STATE_DIR/history/failed-$timestamp-$IMAGE_TAG.env" || true
  fi
  "${SUDO[@]}" rm -rf "$NGINX_BACKUP_DIR" >/dev/null 2>&1 || true
  echo "Deployment failed; active nginx and parquet pointers were preserved or restored" >&2
  exit "$status"
}
trap on_error ERR

echo "Pulling immutable images for $IMAGE_TAG"
"${COMPOSE[@]}" pull backend-tool "$(backend_for_color "$NEXT_COLOR")" "$(frontend_for_color "$NEXT_COLOR")"
"${COMPOSE[@]}" up -d mariadb

if [[ "$PREPARE_DATA" == "true" ]]; then
  backup_tmp="$APP_DIR/backups/.predeploy-$timestamp.sql.tmp"
  echo "Writing pre-deployment database backup"
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
    mariadb-dump -uroot --single-transaction --quick "$MARIADB_DATABASE" > "$backup_tmp"
  cp "$backup_tmp" "$APP_DIR/backups/predeploy-daily.sql"
  week="$(date -u +%G-W%V)"
  month="$(date -u +%Y-%m)"
  if [[ "$(cat "$APP_DIR/backups/.weekly-marker" 2>/dev/null || true)" != "$week" ]]; then
    cp "$backup_tmp" "$APP_DIR/backups/predeploy-weekly.sql"
    printf '%s\n' "$week" > "$APP_DIR/backups/.weekly-marker"
  fi
  if [[ "$(cat "$APP_DIR/backups/.monthly-marker" 2>/dev/null || true)" != "$month" ]]; then
    cp "$backup_tmp" "$APP_DIR/backups/predeploy-monthly.sql"
    printf '%s\n' "$month" > "$APP_DIR/backups/.monthly-marker"
  fi
  rm -f "$backup_tmp"
fi

echo "Applying Django migrations once"
export TOOL_PARQUET_SET_PATH="$ACTIVE_PARQUET_SET"
"${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py migrate --noinput

if [[ "$PREPARE_DATA" == "true" ]]; then
  [[ "$CANDIDATE_PARQUET_SET" == "$PARQUET_ROOT/.staging/"* ]] || {
    echo "Refusing to prepare data outside the parquet staging root" >&2
    exit 1
  }
  rm -rf "$CANDIDATE_PARQUET_SET"
  mkdir -p "$CANDIDATE_PARQUET_SET"
  DERIVED_BACKUP="$APP_DIR/backups/derived-$timestamp.sql"
  existing_derived="$("${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
    mariadb -N -uroot -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MARIADB_DATABASE' AND table_name IN ('GuidelineAdherence','VisitAttributes','SurgeryCaseAttributes')")"
  if [[ "$existing_derived" == "3" ]]; then
    DERIVED_ORIGINAL_STATE="three"
    "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
      mariadb-dump -uroot --single-transaction "$MARIADB_DATABASE" \
      GuidelineAdherence VisitAttributes SurgeryCaseAttributes > "$DERIVED_BACKUP"
    chmod 0600 "$DERIVED_BACKUP"
  elif [[ "$existing_derived" == "0" ]]; then
    DERIVED_ORIGINAL_STATE="zero"
  elif [[ "$existing_derived" != "0" ]]; then
    echo "Expected zero or three SQL-managed derived tables, found $existing_derived" >&2
    false
  fi
  DERIVED_MUTATED=1
  NEW_PARQUET_PATH="$CANDIDATE_PARQUET_SET"
  export TOOL_PARQUET_SET_PATH="$CANDIDATE_PARQUET_SET"
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py migrate_derived_tables
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py refresh_derived_tables
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py generate_parquets
  "${COMPOSE[@]}" run --rm backend-tool poetry run python manage.py validate_parquets \
    --image-tag "$IMAGE_TAG" --source-commit "$SOURCE_COMMIT" --write-manifest
  chmod -R go-rwx "$CANDIDATE_PARQUET_SET"
fi

echo "Starting inactive $NEXT_COLOR application pair"
"${COMPOSE[@]}" stop "$(frontend_for_color "$NEXT_COLOR")" "$(backend_for_color "$NEXT_COLOR")" >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --force-recreate "$(backend_for_color "$NEXT_COLOR")" "$(frontend_for_color "$NEXT_COLOR")"

deadline=$((SECONDS + HEALTH_TIMEOUT))
until smoke_candidate_frontend "http://127.0.0.1:$NEXT_PORT" \
  && curl -fsS --max-time 4 -H 'Host: intelvia.app' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$NEXT_PORT/health/" >/dev/null \
  && curl -fsS --max-time 8 -H 'Host: intelvia.app' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$NEXT_PORT/api/health/" >/dev/null; do
  (( SECONDS < deadline )) || { echo "Candidate health check timed out" >&2; false; }
  sleep 3
done

if [[ "$PREPARE_DATA" == "true" ]]; then
  promoted_set="$PARQUET_ROOT/sets/$PARQUET_SET_ID"
  mv "$CANDIDATE_PARQUET_SET" "$promoted_set"
  CANDIDATE_PARQUET_SET="$promoted_set"
  NEW_PARQUET_PATH="$promoted_set"
fi

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

current_link_tmp="$PARQUET_ROOT/.current-$timestamp"
ln -s "$CANDIDATE_PARQUET_SET" "$current_link_tmp"
mv -Tf "$current_link_tmp" "$PARQUET_ROOT/current"
POINTER_CHANGED=1

if ! curl -fsS --max-time 15 "$PUBLIC_BASE_URL/health/" >/dev/null \
  || ! curl -fsS --max-time 20 "$PUBLIC_BASE_URL/api/health/" >/dev/null; then
  false
fi
deployment_id="$timestamp-$IMAGE_TAG"
state_file="$STATE_DIR/history/$deployment_id.env"
{
  printf 'ACTIVE_COLOR=%q\n' "$NEXT_COLOR"
  printf 'ACTIVE_IMAGE_TAG=%q\n' "$IMAGE_TAG"
  printf 'ACTIVE_SOURCE_COMMIT=%q\n' "$SOURCE_COMMIT"
  printf 'ACTIVE_PARQUET_SET=%q\n' "$CANDIDATE_PARQUET_SET"
  printf 'PREVIOUS_COLOR=%q\n' "$ACTIVE_COLOR"
  printf 'PREVIOUS_IMAGE_TAG=%q\n' "$ACTIVE_IMAGE_TAG"
  printf 'PREVIOUS_SOURCE_COMMIT=%q\n' "$ACTIVE_SOURCE_COMMIT"
  printf 'PREVIOUS_PARQUET_SET=%q\n' "$ACTIVE_PARQUET_SET"
  printf 'DATA_PREPARED=%q\n' "$PREPARE_DATA"
  printf 'DEPLOYED_AT=%q\n' "$timestamp"
  printf 'DEPLOYMENT_ID=%q\n' "$deployment_id"
} > "$state_file"
cp "$state_file" "$STATE_DIR/current.env"
CUTOVER_COMPLETE=1
DERIVED_MUTATED=0
NEW_PARQUET_PATH=""

"${COMPOSE[@]}" stop "$(frontend_for_color "$ACTIVE_COLOR")" "$(backend_for_color "$ACTIVE_COLOR")" >/dev/null 2>&1 || true
"${SUDO[@]}" rm -rf "$NGINX_BACKUP_DIR" || true
for stale_staging in "$PARQUET_ROOT/.staging/"*; do
  [[ -e "$stale_staging" ]] || continue
  rm -rf -- "$stale_staging" || true
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
  rm -rf -- "$parquet_set" || true
done
docker image prune -a -f --filter "until=${IMAGE_PRUNE_AGE:-168h}" || true
echo "Deployment complete: id=$deployment_id color=$NEXT_COLOR image=$IMAGE_TAG parquets=$CANDIDATE_PARQUET_SET prepared=$PREPARE_DATA"
