#!/usr/bin/env bash
# Build and (re)deploy CLARTO staging from the pinned sources. Safe to re-run.
#
#   scripts/deploy.sh            # full deploy
#   scripts/deploy.sh --no-build # reuse already-built images
source "$(dirname "$0")/lib.sh"
require_env_file

BUILD=1
[ "${1:-}" = "--no-build" ] && BUILD=0

log "PWB ref ${PWB_REF}  |  Liberu ref ${LIBERU_REF}"
"$BUNDLE_DIR/scripts/fetch-sources.sh"

if [ "$BUILD" = 1 ]; then
  log "building images"
  dc build --pull
fi

log "starting shared services"
dc up -d redis
wait_healthy redis 60

log "Liberu: migrations"
dc run --rm --no-deps -T liberu-app php artisan migrate --force
if [ "$(dc run --rm --no-deps -T liberu-app php artisan tinker --execute='echo \App\Models\User::count();' | tail -n1 | tr -dc 0-9)" = "0" ]; then
  log "Liberu: first deploy — seeding teams, roles and admin (no demo properties)"
  for seeder in \
    'Liberu\RealEstate\Application\Database\Seeders\TeamSeeder' \
    'Liberu\RealEstate\Core\Database\Seeders\TerritorySeeder' \
    'Liberu\RealEstate\Application\Database\Seeders\RolesSeeder' \
    'Liberu\RealEstate\Application\Database\Seeders\RealEstateRolesSeeder' \
    'Liberu\RealEstate\Application\Database\Seeders\SignupRolesSeeder' \
    'Liberu\RealEstate\Application\Database\Seeders\UserSeeder'; do
    dc run --rm --no-deps -T liberu-app php artisan db:seed --force --class="$seeder"
  done
fi

log "panel: CLARTO identity settings"
"$BUNDLE_DIR/scripts/brand-settings.sh"

if [ "${ENABLE_PWB:-false}" = true ]; then
  # PropertyWebBuilder is paused (compose profile "pwb"); kept runnable on demand.
  export COMPOSE_PROFILES=pwb
  log "PWB: migrations and staging bootstrap"
  dc up -d pwb-db && wait_healthy pwb-db 120
  dc run --rm --no-deps -T pwb-web bundle exec rake db:migrate
  dc run --rm --no-deps -T -e PWB_ADMIN_EMAIL -e PWB_ADMIN_PASSWORD pwb-web bundle exec rake pwb:clarto_staging:bootstrap
fi

log "starting the full stack"
dc up -d --remove-orphans
wait_healthy liberu-app 300
wait_healthy caddy 60

mkdir -p "$BUNDLE_DIR/state"
{
  echo "deployed_at=$(date -u +%FT%TZ)"
  echo "pwb_ref=${PWB_REF}"
  echo "liberu_ref=${LIBERU_REF}"
  dc images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null || dc images
} > "$BUNDLE_DIR/state/last-deploy.txt"

log "done — https://${LIBERU_HOST} (panel)"
