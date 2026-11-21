#!/usr/bin/env bash
# Connects the panel to the CLARTO GoHighLevel sub-account. The Private Integration token is typed here, on the
# server, and only stored in .env (mode 600); it is never printed.
#
#   scripts/set-ghl.sh <location-id>     # then paste the Private Integration token (not shown)
#   scripts/set-ghl.sh --test            # check the stored token against GHL (prints only the result)
source "$(dirname "$0")/lib.sh"
require_env_file

set_env() { # set_env KEY VALUE (replace or append, value kept literal)
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"; grep -v "^${key}=" "$BUNDLE_DIR/.env" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$BUNDLE_DIR/.env"; rm -f "$tmp"; chmod 600 "$BUNDLE_DIR/.env"
}

check() { # GET the sub-account with the stored token, from inside the panel container
  dc exec -T liberu-app sh -c 'curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $GHL_API_TOKEN" -H "Version: 2021-07-28" -H "Accept: application/json" \
    "https://services.leadconnectorhq.com/locations/$GHL_LOCATION_ID"'
}

if [ "${1:-}" = "--test" ]; then
  code="$(check)"
  case "$code" in
    200) log "GHL OK: the token reads the sub-account" ;;
    401|403) die "GHL answered $code: token invalid or without the locations.readonly scope" ;;
    *) die "GHL answered $code" ;;
  esac
  exit 0
fi

location="${1:?usage: set-ghl.sh <location-id>  (GHL: Settings → Business Profile → Location ID)}"
[[ "$location" =~ ^[A-Za-z0-9]{10,40}$ ]] || die "that does not look like a Location ID"
[ -t 0 ] || die "run it in an interactive terminal: the token is read from the keyboard"
read -r -s -p "Private Integration token (not shown): " token; echo
[ -n "$token" ] || die "empty token"
[[ "$token" =~ ^[A-Za-z0-9._-]+$ ]] || die "unexpected characters in the token; copy it again from GHL"

set_env GHL_API_TOKEN "$token"
set_env GHL_LOCATION_ID "$location"
grep -qE '^GHL_WEBHOOK_SECRET=.+' "$BUNDLE_DIR/.env" || set_env GHL_WEBHOOK_SECRET "$(openssl rand -hex 24)"
unset token
dc up -d --force-recreate liberu-app liberu-worker liberu-scheduler >/dev/null
sleep 5
code="$(check)"
[ "$code" = 200 ] && log "GHL connected (sub-account $location). The pipeline and fields are created next." \
  || die "token saved, but GHL answered $code: check the token scopes and the Location ID, then run it again"
