#!/usr/bin/env bash
# Restore a CLARTO panel backup (SQLite database + file volume).
#
#   sudo scripts/restore.sh <backup-dir> --yes               # restore over the live panel
#   sudo scripts/restore.sh <backup-dir> --yes --with-env    # also put back that backup's .env
#   COMPOSE_PROJECT=clarto-restoretest scripts/restore.sh <dir> --yes --scratch
#                                                            # isolated copy (used by restore-test.sh)
#
# A live restore stops the panel, replaces its volume (database included) and starts it again.
# Take a fresh backup first if in doubt.
source "$(dirname "$0")/lib.sh"

src="${1:-}"; shift || true
[ -n "$src" ] && [ -d "$src" ] || die "usage: restore.sh <backup-dir> --yes [--with-env] [--scratch]"
src="$(cd "$src" && pwd -P)"
YES=0 WITH_ENV=0 SCRATCH=0
for arg in "$@"; do
  case "$arg" in --yes) YES=1 ;; --with-env) WITH_ENV=1 ;; --scratch) SCRATCH=1 ;; *) die "unknown argument $arg" ;; esac
done
[ "$YES" = 1 ] || die "refusing to restore without --yes (this replaces data in project ${COMPOSE_PROJECT})"

log "verifying checksums of $src"
(cd "$src" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch in $src"

if [ "$SCRATCH" = 1 ]; then
  cp "$src/env" "$BUNDLE_DIR/.env.restoretest"
  dc() { docker compose -p "$COMPOSE_PROJECT" --env-file "$BUNDLE_DIR/.env.restoretest" -f "$BUNDLE_DIR/compose.yaml" "$@"; }
else
  [ "$WITH_ENV" = 1 ] && { cp "$BUNDLE_DIR/.env" "$BUNDLE_DIR/.env.before-restore.$(date -u +%s)" 2>/dev/null || true; cp "$src/env" "$BUNDLE_DIR/.env"; chmod 600 "$BUNDLE_DIR/.env"; }
  require_env_file
  cmp -s "$src/env" "$BUNDLE_DIR/.env" || log "WARNING: current .env differs from the backup's; APP_KEY must match the data (use --with-env)"
  log "[$COMPOSE_PROJECT] stopping the panel"
  dc stop liberu-app liberu-worker liberu-scheduler 2>/dev/null || true
fi

log "restoring volume liberu_storage (files + database)"
docker volume create "${COMPOSE_PROJECT}_liberu_storage" > /dev/null
docker run --rm -v "${COMPOSE_PROJECT}_liberu_storage:/data" -v "$src:/backup:ro" alpine:3.22 sh -c '
  find /data -mindepth 1 -delete
  tar -C /data -xzf /backup/liberu_storage.tar.gz
  mkdir -p /data/db && gunzip -c /backup/liberu-db.sqlite.gz > /data/db/panel.sqlite
  chown -R 33:33 /data'

if [ "$SCRATCH" = 1 ]; then
  log "[$COMPOSE_PROJECT] scratch restore done (apps not started)"
  exit 0
fi

dc up -d liberu-app liberu-worker liberu-scheduler
wait_healthy liberu-app 300
log "restore of $(basename "$src") complete"
