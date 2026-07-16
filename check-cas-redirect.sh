#!/usr/bin/env bash
set -Eeuo pipefail

base_url="${1:?usage: check-cas-redirect.sh BASE_URL [ENDPOINT]}"
endpoint="${2:-/api/me}"
app_origin="${APP_ORIGIN:-https://intelvia.app}"
cas_server_url="${CAS_SERVER_URL:-https://go.utah.edu/cas/}"
headers_file="$(mktemp)"
body_file="$(mktemp)"
trap 'rm -f "$headers_file" "$body_file"' EXIT

current_url="$base_url$endpoint"

if [[ "${DJANGO_DISABLE_LOGINS:-False}" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn])$ ]]; then
  status="$(curl -sS --max-time 8 -o "$body_file" -w '%{http_code}' \
    -H 'Host: intelvia.app' -H 'X-Forwarded-Proto: https' "$current_url")"
  if [[ "$status" != "200" ]]; then
    echo "Login-disabled auth endpoint returned HTTP $status instead of 200" >&2
    exit 1
  fi
  if ! rg -q '"username"[[:space:]]*:[[:space:]]*"login-disabled"' "$body_file" 2>/dev/null \
    && ! grep -Eq '"username"[[:space:]]*:[[:space:]]*"login-disabled"' "$body_file"; then
    echo "Login-disabled auth endpoint did not return the expected access payload" >&2
    exit 1
  fi
  exit 0
fi

for _ in {1..4}; do
  : > "$headers_file"
  status="$(curl -sS --max-time 8 -D "$headers_file" -o /dev/null -w '%{http_code}' \
    -H 'Host: intelvia.app' -H 'X-Forwarded-Proto: https' "$current_url")"
  case "$status" in
    301|302|303|307|308) ;;
    *)
      echo "Auth endpoint did not redirect toward CAS (HTTP $status)" >&2
      exit 1
      ;;
  esac

  location="$(awk 'tolower($1) == "location:" {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}' "$headers_file")"
  [[ -n "$location" ]] || { echo "Auth redirect omitted the Location header" >&2; exit 1; }

  if [[ "$location" == "$cas_server_url"* ]]; then
    exit 0
  fi

  case "$location" in
    /api/accounts/login*)
      current_url="$base_url$location"
      ;;
    "$app_origin"/api/accounts/login*)
      current_url="$base_url${location#"$app_origin"}"
      ;;
    *)
      echo "Auth endpoint redirected to an unexpected location: $location" >&2
      exit 1
      ;;
  esac
done

echo "Auth endpoint did not reach CAS within four redirects" >&2
exit 1
