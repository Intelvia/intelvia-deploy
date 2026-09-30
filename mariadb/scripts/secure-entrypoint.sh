#!/usr/bin/env bash
set -Eeuo pipefail

readonly SOURCE_DIR=/run/intelvia-source-secrets
readonly TARGET_DIR=/run/intelvia-mariadb-secrets

install -d -o mysql -g mysql -m 0700 "$TARGET_DIR"
install -o mysql -g mysql -m 0400 \
  "$SOURCE_DIR/encryption-keys.enc" \
  "$TARGET_DIR/encryption-keys.enc"
install -o mysql -g mysql -m 0400 \
  "$SOURCE_DIR/encryption-key-password" \
  "$TARGET_DIR/encryption-key-password"
install -o mysql -g mysql -m 0400 \
  "$SOURCE_DIR/server-key.pem" \
  "$TARGET_DIR/server-key.pem"
install -o mysql -g mysql -m 0444 \
  "$SOURCE_DIR/ca.pem" \
  "$TARGET_DIR/ca.pem"
install -o mysql -g mysql -m 0444 \
  "$SOURCE_DIR/server-cert.pem" \
  "$TARGET_DIR/server-cert.pem"

exec /usr/local/bin/docker-entrypoint.sh "$@"
