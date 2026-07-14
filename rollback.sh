#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 1 )); then
  echo "Usage: $0 DEPLOYMENT_ID" >&2
  exit 2
fi

if [[ ! "$1" =~ ^[0-9]{8}T[0-9]{6}Z-(sha-[0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?)$ ]]; then
  echo "Invalid deployment ID" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/deploy.sh" --rollback-state "$1"
