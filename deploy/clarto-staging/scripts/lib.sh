#!/usr/bin/env bash
# Shared helpers for the CLARTO staging scripts. Source, don't execute.
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$BUNDLE_DIR/../.." && pwd)"
cd "$BUNDLE_DIR"

# shellcheck disable=SC1091
source "$BUNDLE_DIR/versions.env"
export LIBERU_REF
PWB_REF="$(git -C "$REPO_DIR" rev-parse HEAD)"
export PWB_REF

# Website preview: enabled once a website snapshot was uploaded (scripts/upload-web.sh).
if [ -f "$BUNDLE_DIR/src/web/.source-ref" ]; then
  WEB_REF="$(cat "$BUNDLE_DIR/src/web/.source-ref")"
  export WEB_REF
  export COMPOSE_PROFILES="${COMPOSE_PROFILES:+$COMPOSE_PROFILES,}preview"
fi

# Watermark removal (IOPaint): the service runs only once .env sets IOPAINT_URL (e.g. http://iopaint:8080).
if grep -Eq '^IOPAINT_URL=.+' "$BUNDLE_DIR/.env" 2>/dev/null; then
  export COMPOSE_PROFILES="${COMPOSE_PROFILES:+$COMPOSE_PROFILES,}marcas-agua"
fi

COMPOSE_PROJECT="${COMPOSE_PROJECT:-clarto-staging}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/clarto-staging/backups}"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

dc() { docker compose -p "$COMPOSE_PROJECT" --env-file "$BUNDLE_DIR/.env" -f "$BUNDLE_DIR/compose.yaml" "$@"; }

require_env_file() {
  [ -f "$BUNDLE_DIR/.env" ] || die ".env missing: run scripts/init-env.sh first"
  set -a; source "$BUNDLE_DIR/.env"; set +a
}

wait_healthy() { # wait_healthy <service> [timeout_seconds]
  local svc="$1" timeout="${2:-300}" waited=0 cid status
  cid="$(dc ps -q "$svc")"
  [ -n "$cid" ] || die "service $svc is not running"
  while :; do
    # containers with a HEALTHCHECK must report healthy; others must be running
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")"
    case "$status" in healthy|running) return 0 ;; esac
    [ "$waited" -ge "$timeout" ] && { dc logs --tail 80 "$svc" >&2; die "$svc not healthy after ${timeout}s (status: $status)"; }
    sleep 5; waited=$((waited + 5))
  done
}

liberu_artisan() { dc exec -T -u www-data liberu-app php artisan "$@"; }
pwb_rake() { dc exec -T pwb-web bundle exec rake "$@"; }
