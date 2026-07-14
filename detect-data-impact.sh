#!/usr/bin/env bash
set -Eeuo pipefail

BASE_COMMIT="${1:-}"
HEAD_COMMIT="${2:-HEAD}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/.git" ]]; then
  ROOT_DIR="$SCRIPT_DIR"
else
  ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
PATTERNS_FILE="$SCRIPT_DIR/data-impact-paths.txt"

if [[ -z "$BASE_COMMIT" || "$BASE_COMMIT" == "unknown" ]] || ! git -C "$ROOT_DIR" cat-file -e "$BASE_COMMIT^{commit}" 2>/dev/null; then
  echo "true"
  exit 0
fi

mapfile -t patterns < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$PATTERNS_FILE")
while IFS= read -r changed_path; do
  for pattern in "${patterns[@]}"; do
    if [[ "$changed_path" == $pattern ]]; then
      echo "true"
      exit 0
    fi
  done
done < <(git -C "$ROOT_DIR" diff --name-only "$BASE_COMMIT" "$HEAD_COMMIT")

echo "false"
