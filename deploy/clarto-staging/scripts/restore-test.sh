#!/usr/bin/env bash
# Proves a backup can be restored WITHOUT touching the live stack: restores it
# into a throwaway compose project (separate volumes, no published ports),
# boots both apps against the restored data, checks row counts against the
# backup manifest and that restored photos are readable, then removes it.
#
#   scripts/restore-test.sh [backup-dir]     # default: $BACKUP_ROOT/latest
source "$(dirname "$0")/lib.sh"

src="${1:-$BACKUP_ROOT/latest}"
[ -d "$src" ] || die "no backup at $src"
src="$(cd "$src" && pwd -P)"
TEST_PROJECT=clarto-restoretest

cleanup() {
  docker compose -p "$TEST_PROJECT" --env-file "$BUNDLE_DIR/.env.restoretest" -f "$BUNDLE_DIR/compose.yaml" down -v --remove-orphans > /dev/null 2>&1 || true
  rm -f "$BUNDLE_DIR/.env.restoretest"
}
trap cleanup EXIT

COMPOSE_PROJECT="$TEST_PROJECT" "$BUNDLE_DIR/scripts/restore.sh" "$src" --yes --scratch

t() { docker compose -p "$TEST_PROJECT" --env-file "$BUNDLE_DIR/.env.restoretest" -f "$BUNDLE_DIR/compose.yaml" "$@"; }
expect() { grep "^$1=" "$src/manifest.txt" | cut -d= -f2; }

liberu_props="$(t exec -T liberu-db sh -c 'mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" liberu -e "SELECT COUNT(*) FROM real_estate_properties"' 2>/dev/null | tr -dc 0-9)"
pwb_assets="$(t exec -T pwb-db psql -U pwb -d pwb_staging -tAc 'SELECT COUNT(*) FROM pwb_realty_assets' | tr -dc 0-9)"
pwb_blobs="$(t exec -T pwb-db psql -U pwb -d pwb_staging -tAc 'SELECT COUNT(*) FROM active_storage_blobs' | tr -dc 0-9)"

fail=0
check() { if [ "$2" = "$3" ]; then log "OK   $1 = $2"; else log "FAIL $1: restored=$2 expected=$3"; fail=1; fi; }
check liberu_properties "$liberu_props" "$(expect liberu_properties)"
check pwb_realty_assets "$pwb_assets" "$(expect pwb_realty_assets)"
check pwb_blobs "$pwb_blobs" "$(expect pwb_blobs)"

# Boot the apps on the restored data (no ports published: caddy is not started).
t up -d --no-deps liberu-app pwb-web
COMPOSE_PROJECT="$TEST_PROJECT"
dc() { t "$@"; }
wait_healthy liberu-app 300
wait_healthy pwb-web 300

liberu_api="$(t exec -T liberu-app curl -fsS -o /dev/null -w '%{http_code}' http://localhost/api/v1/public/properties)"
check liberu_public_api_http "$liberu_api" 200

blob_check="$(t exec -T pwb-web bundle exec rails runner '
  blobs = ActiveStorage::Blob.all.to_a
  ok = blobs.count { |b| b.service.exist?(b.key) && Digest::MD5.base64digest(b.download) == b.checksum }
  puts "#{ok}/#{blobs.size}"' 2>/dev/null | tail -n1)"
check pwb_blobs_readable_and_intact "${blob_check%%/*}" "${blob_check##*/}"

[ "$fail" = 0 ] || die "restore test FAILED for $(basename "$src")"
log "restore test PASSED for $(basename "$src")"
