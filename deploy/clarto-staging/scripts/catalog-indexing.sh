#!/usr/bin/env bash
# Controls whether search engines may index the public catalog.
#
#   scripts/catalog-indexing.sh status
#   scripts/catalog-indexing.sh off        # noindex header + robots.txt "Disallow: /" (default)
#   scripts/catalog-indexing.sh on         # refuses while fictitious listings remain
#
# Going live, in order:
#   1. Withdraw (or delete) every fictitious property in the panel.
#   2. Set CATALOG_TEST_LABEL= (empty) in .env and run scripts/deploy.sh --no-build,
#      which re-syncs and removes the "Inmueble de prueba" marks.
#   3. scripts/catalog-indexing.sh on
source "$(dirname "$0")/lib.sh"
require_env_file

label="${CATALOG_TEST_LABEL-Inmueble de prueba}"
visible_marked() {
  local needle="${1:-Inmueble de prueba}"
  dc exec -T pwb-db psql -U pwb -d pwb_staging -tAc \
    "SELECT COUNT(*) FROM pwb_realty_assets a
       WHERE (a.title ILIKE '%' || \$\$${needle}\$\$ || '%')
         AND (EXISTS (SELECT 1 FROM pwb_sale_listings s WHERE s.realty_asset_id = a.id AND s.visible)
           OR EXISTS (SELECT 1 FROM pwb_rental_listings r WHERE r.realty_asset_id = a.id AND r.visible))" | tr -dc 0-9
}

set_env() { # set_env KEY VALUE
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}

case "${1:-status}" in
  status)
    echo "CATALOG_INDEXING=${CATALOG_INDEXING:-off}"
    echo "CATALOG_TEST_LABEL='${label}'"
    echo "visible listings still marked as test: $(visible_marked "${label:-Inmueble de prueba}")"
    ;;
  off)
    set_env CATALOG_INDEXING off
    dc up -d --force-recreate caddy
    log "indexing OFF: noindex + robots.txt Disallow on https://${PWB_HOST}"
    ;;
  on)
    [ -z "$label" ] || die "CATALOG_TEST_LABEL is still '${label}': withdraw the fictitious listings, empty it and redeploy first"
    marked="$(visible_marked "Inmueble de prueba")"
    [ "$marked" = 0 ] || die "${marked} visible listing(s) still marked 'Inmueble de prueba' — withdraw them before enabling indexing"
    set_env CATALOG_INDEXING on
    dc up -d --force-recreate caddy
    log "indexing ON for https://${PWB_HOST}"
    ;;
  *) die "usage: catalog-indexing.sh status|on|off" ;;
esac
