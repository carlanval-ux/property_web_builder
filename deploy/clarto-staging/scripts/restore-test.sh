#!/usr/bin/env bash
# Proves a backup can be restored WITHOUT touching the live stack: restores it into a
# throwaway compose project (own volume, no published ports), boots the panel on the
# restored data, runs pending migrations there (so a new image can be tried on real data
# before deploying it), and checks row counts against the backup manifest.
#
#   sudo scripts/restore-test.sh [backup-dir]     # default: $BACKUP_ROOT/latest
source "$(dirname "$0")/lib.sh"

src="${1:-$BACKUP_ROOT/latest}"
[ -d "$src" ] || die "no backup at $src"
src="$(cd "$src" && pwd -P)"
TEST_PROJECT=clarto-restoretest

t() { docker compose -p "$TEST_PROJECT" --env-file "$BUNDLE_DIR/.env.restoretest" -f "$BUNDLE_DIR/compose.yaml" "$@"; }
cleanup() { t down -v --remove-orphans > /dev/null 2>&1 || true; rm -f "$BUNDLE_DIR/.env.restoretest"; }
trap cleanup EXIT

COMPOSE_PROJECT="$TEST_PROJECT" "$BUNDLE_DIR/scripts/restore.sh" "$src" --yes --scratch

COMPOSE_PROJECT="$TEST_PROJECT"
dc() { t "$@"; }
t up -d --no-deps redis liberu-app
wait_healthy liberu-app 300

t exec -T -u www-data liberu-app php artisan migrate --force --no-interaction
pending="$(t exec -T -u www-data liberu-app php artisan migrate:status | grep -c Pending || true)"

count() { t exec -T -u www-data liberu-app php -r '$p = new PDO("sqlite:" . getenv("DB_DATABASE")); echo $p->query("SELECT COUNT(*) FROM '"$1"'")->fetchColumn();' | tr -dc 0-9; }
expect() { grep "^$1=" "$src/manifest.txt" | cut -d= -f2; }

fail=0
check() { if [ "$2" = "$3" ]; then log "OK   $1 = $2"; else log "FAIL $1: restored=$2 expected=$3"; fail=1; fi; }
check liberu_properties "$(count real_estate_properties)" "$(expect liberu_properties)"
check liberu_users "$(count users)" "$(expect liberu_users)"
check liberu_media "$(count real_estate_media_documents)" "$(expect liberu_media)"
check pending_migrations "$pending" 0
check panel_login_http "$(t exec -T liberu-app curl -s -o /dev/null -w '%{http_code}' http://localhost/admin/login)" 200
check catalog_api_without_key "$(t exec -T liberu-app curl -s -o /dev/null -w '%{http_code}' http://localhost/api/v1/catalogo/inmuebles)" 401

[ "$fail" = 0 ] || die "restore test FAILED for $(basename "$src")"
log "restore test PASSED for $(basename "$src")"
