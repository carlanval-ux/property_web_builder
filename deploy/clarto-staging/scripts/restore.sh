#!/usr/bin/env bash
# Restore a CLARTO staging backup.
#
#   scripts/restore.sh <backup-dir> --yes                 # restore over the live stack
#   scripts/restore.sh <backup-dir> --yes --with-env      # also put back that backup's .env
#   COMPOSE_PROJECT=clarto-restoretest scripts/restore.sh <dir> --yes --scratch
#                                                         # isolated copy (used by restore-test.sh)
#
# Live restore stops the apps, replaces both databases and both photo volumes,
# then starts everything again. Take a fresh backup first if in doubt.
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
  # Isolated project: use the backup's own env so keys match the data.
  cp "$src/env" "$BUNDLE_DIR/.env.restoretest"
  dc() { docker compose -p "$COMPOSE_PROJECT" --env-file "$BUNDLE_DIR/.env.restoretest" -f "$BUNDLE_DIR/compose.yaml" "$@"; }
  set -a; source "$BUNDLE_DIR/.env.restoretest"; set +a
else
  [ "$WITH_ENV" = 1 ] && { cp "$BUNDLE_DIR/.env" "$BUNDLE_DIR/.env.before-restore.$(date -u +%s)" 2>/dev/null || true; cp "$src/env" "$BUNDLE_DIR/.env"; chmod 600 "$BUNDLE_DIR/.env"; }
  require_env_file
  if ! cmp -s "$src/env" "$BUNDLE_DIR/.env"; then
    log "WARNING: current .env differs from the backup's; Laravel APP_KEY / Rails SECRET_KEY_BASE must match the data (use --with-env)"
  fi
fi

APPS="caddy liberu-app liberu-worker liberu-scheduler pwb-web pwb-worker pwb-sync"
log "[$COMPOSE_PROJECT] stopping applications"
# shellcheck disable=SC2086
dc stop $APPS 2>/dev/null || true

log "[$COMPOSE_PROJECT] starting databases"
dc up -d pwb-db redis
wait_healthy pwb-db 120

log "restoring Liberu database"
dc exec -T liberu-db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS liberu; CREATE DATABASE liberu CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL ON liberu.* TO \"liberu\"@\"%\";"'
gunzip -c "$src/liberu-db.sql.gz" | dc exec -T liberu-db sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

log "restoring PWB database"
dc exec -T pwb-db psql -U pwb -d postgres -qc 'DROP DATABASE IF EXISTS pwb_staging WITH (FORCE);' -c 'CREATE DATABASE pwb_staging OWNER pwb;'
dc exec -T pwb-db pg_restore -U pwb -d pwb_staging --no-owner --exit-on-error < "$src/pwb-db.dump"

for vol in liberu_storage pwb_storage; do
  log "restoring volume $vol"
  docker volume create "${COMPOSE_PROJECT}_${vol}" > /dev/null
  docker run --rm -v "${COMPOSE_PROJECT}_${vol}:/data" -v "$src:/backup:ro" alpine:3.22 \
    sh -c "find /data -mindepth 1 -delete && tar -C /data -xzf /backup/${vol}.tar.gz"
done

if [ "$SCRATCH" = 1 ]; then
  log "[$COMPOSE_PROJECT] scratch restore done (apps not started)"
  exit 0
fi

log "starting applications"
dc up -d
wait_healthy liberu-app 300
wait_healthy pwb-web 300
log "restore of $(basename "$src") complete"
