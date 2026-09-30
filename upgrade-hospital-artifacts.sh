#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f .env ]]; then
  echo "Missing .env" >&2
  exit 1
fi

artifact_key="$(sed -n 's/^ARTIFACT_ENCRYPTION_KEY=//p' .env | tail -n 1)"
if [[ -z "$artifact_key" ]]; then
  echo "Set a stable ARTIFACT_ENCRYPTION_KEY in .env before upgrading." >&2
  exit 1
fi
if [[ "$(printf '%s' "$artifact_key" | openssl base64 -d -A | wc -c | tr -d ' ')" != "32" ]]; then
  echo "ARTIFACT_ENCRYPTION_KEY must be a base64-encoded 32-byte key." >&2
  exit 1
fi
image_tag="$(sed -n 's/^INTELVIA_IMAGE_TAG=//p' .env | tail -n 1)"
if [[ -z "$image_tag" ]]; then
  echo "Set INTELVIA_IMAGE_TAG in .env before upgrading." >&2
  exit 1
fi

# Pull while the old application is still available. Once files are rewritten,
# an old backend cannot read them; leave the application stopped on failure.
docker compose pull
docker compose --profile tools run --rm --no-deps --entrypoint sh backend-refresh-tool -c \
  'test -f /app/api/artifact_encryption.py && test -f /app/api/management/commands/prepare_parquet_set.py &&
   poetry run python manage.py shell -c '\''from api.artifact_encryption import MAGIC, encrypted_reader
from api.artifacts import active_artifact_dir, cache_dir
artifact = active_artifact_dir(cache_dir()) / "visit_attributes.parquet"
if artifact.is_file():
    with artifact.open("rb") as source:
        encrypted = source.read(len(MAGIC)) == MAGIC
    if encrypted:
        encrypted_reader(artifact).close()'\''' || {
  echo "The backend image cannot upgrade artifacts or the configured key cannot read existing encrypted data." >&2
  exit 1
}
docker compose stop frontend backend celery-worker celery-beat
docker compose up -d --wait mariadb redis
docker compose --profile tools run --rm backend-tool poetry run python manage.py migrate --noinput
docker compose --profile tools run --rm backend-tool poetry run python manage.py guideline_config_version
docker compose run --rm mariadb-finalize-grants
docker compose --profile tools run --rm backend-refresh-tool poetry run python manage.py prepare_parquet_set --commit
docker compose --profile tools run --rm backend-refresh-tool poetry run python manage.py encrypt_legacy_artifacts
docker compose --profile tools run --rm backend-refresh-tool poetry run python manage.py validate_parquets \
  --image-tag "$image_tag" \
  --source-commit operator-managed --write-manifest
docker compose up -d --wait
curl -fsS http://127.0.0.1:8080/api/health/
