#!/usr/bin/env bash
# End-to-end check of the Liberu -> PWB catalog flow on a running stack, with a
# fictitious property. Every step goes through the real interfaces: Liberu's
# authenticated REST API for the back office, the sync task, and PWB's public
# HTTPS site/API (through Caddy) for the catalog.
#
#   scripts/e2e-flow.sh            # writes state/e2e-<timestamp>.log and exits non-zero on failure
#
# Steps:
#   0. baseline: sync once; remember catalog/asset counts
#   1. alta: create the property in Liberu as DRAFT + a second draft-only property
#   2. borrador: sync -> neither property is in the catalog
#   3. publicación: transition to "available" -> sync -> visible in catalog (list + detail)
#   4. reintento: sync again -> nothing created, no duplicate assets/listings/photos
#   5. precio + fotos: change price, attach 2 photos -> sync -> price and 2 photos in catalog
#   6. cambio de fotos: replace one photo -> sync -> still 2 photos, the new one included
#   7. retirada: transition to "withdrawn" -> sync -> gone from list and detail page
#   8. cleanup marker: the test property stays withdrawn (audit trail), drafts stay drafts
source "$(dirname "$0")/lib.sh"
require_env_file

mkdir -p "$BUNDLE_DIR/state"
LOG="$BUNDLE_DIR/state/e2e-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); log "PASS  $*"; }
bad()  { FAIL=$((FAIL + 1)); log "FAIL  $*"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

RUN_ID="$(date -u +%H%M%S)"
TITLE="E2E CLARTO ficticio ${RUN_ID}"
DRAFT_TITLE="E2E CLARTO borrador ${RUN_ID}"

# --- helpers ------------------------------------------------------------------
TOKEN="$(dc exec -T -u www-data liberu-app php artisan tinker --execute='
  $u = \App\Models\User::where("email", "admin@example.com")->firstOrFail();
  echo $u->createToken("e2e-'"$RUN_ID"'")->plainTextToken;' | tail -n1 | tr -d '\r')"
[ -n "$TOKEN" ] || die "could not create a Liberu API token"

# Liberu API, called inside the app container (same code path as over HTTPS, no basic auth involved)
lapi() { # lapi METHOD PATH [JSON]
  dc exec -T liberu-app curl -sS -X "$1" "http://localhost$2" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" -H "Idempotency-Key: e2e-$RUN_ID-$RANDOM$RANDOM" \
    ${3:+--data "$3"}
}

# PWB public catalog, called over HTTPS through Caddy exactly as a visitor would
CURL_TLS=()
[ "${TLS_MODE:-}" = internal ] && CURL_TLS=(-k)
catalog() { # catalog PATH -> body
  curl -sS "${CURL_TLS[@]}" --resolve "${PWB_HOST}:443:127.0.0.1" "https://${PWB_HOST}$1"
}
catalog_code() {
  curl -sS -o /dev/null -w '%{http_code}' "${CURL_TLS[@]}" --resolve "${PWB_HOST}:443:127.0.0.1" "https://${PWB_HOST}$1"
}

sync() { dc exec -T pwb-sync bundle exec rake pwb:liberu:sync | tee /dev/stderr | grep '^\[liberu-sync\]' | tail -n1; }

pwb_sql() { dc exec -T pwb-db psql -U pwb -d pwb_staging -tAc "$1" | tr -d '\r'; }
asset_count_for() { pwb_sql "SELECT COUNT(*) FROM pwb_realty_assets WHERE reference = '$1'"; }
visible_listing_count_for() {
  pwb_sql "SELECT COUNT(*) FROM pwb_sale_listings s JOIN pwb_realty_assets a ON a.id = s.realty_asset_id WHERE a.reference = '$1' AND s.visible"
}
price_cents_for() {
  pwb_sql "SELECT s.price_sale_current_cents FROM pwb_sale_listings s JOIN pwb_realty_assets a ON a.id = s.realty_asset_id WHERE a.reference = '$1' AND s.active"
}
photo_count_for() { pwb_sql "SELECT COUNT(*) FROM pwb_prop_photos p JOIN pwb_realty_assets a ON a.id = p.realty_asset_id WHERE a.reference = '$1'"; }
slug_for() { pwb_sql "SELECT slug FROM pwb_realty_assets WHERE reference = '$1'"; }
in_catalog_api() { catalog "/api_public/v1/es/properties?sale_or_rental=sale&per_page=100" | grep -q "$1"; }
in_catalog_html() { catalog "/es/buy" | grep -q "$1"; }
page_matches() { catalog "$1" | grep -Eq "$2"; }
not() { ! "$@"; }

json_field() { python3 -c "import json,sys; d=json.load(sys.stdin); d=d.get('data', d); print(d$1)"; }

put_photo() { # put_photo NAME COLOR -> path relative to Liberu public disk
  local name="$1" color="$2"
  dc exec -T -u www-data liberu-app php -r '
    $img = imagecreatetruecolor(640, 480);
    imagefill($img, 0, 0, hexdec("'"$color"'"));
    @mkdir("storage/app/public/e2e", 0775, true);
    imagejpeg($img, "storage/app/public/e2e/'"$name"'.jpg", 85);' >/dev/null
  echo "e2e/${name}.jpg"
}

# --- 0. baseline ------------------------------------------------------------------
log "== 0. baseline"
sync >/dev/null || true
assets_before="$(pwb_sql 'SELECT COUNT(*) FROM pwb_realty_assets')"

# --- 1. alta en Liberu (borrador) --------------------------------------------------
log "== 1. alta en Liberu"
created="$(lapi POST /api/v1/real-estate/properties "{\"title\":\"$TITLE\",\"address\":\"Calle Ficticia 1, Madrid\",\"description\":\"Inmueble ficticio de pruebas E2E\",\"property_type\":\"apartment\",\"deal_type\":\"sale\",\"price\":250000,\"currency\":\"EUR\",\"bedrooms\":3,\"bathrooms\":2,\"area_sqft\":1076.39}")"
PROP_ID="$(echo "$created" | json_field "['id']" 2>/dev/null || true)"
REF="$(echo "$created" | json_field "['reference']" 2>/dev/null || true)"
if [ -z "$PROP_ID" ] || [ -z "$REF" ]; then
  log "Liberu response: $created"; die "could not create the test property in Liberu"
fi
log "Liberu property id=$PROP_ID reference=$REF"
check "alta: Liberu creates it as draft" test "$(echo "$created" | json_field "['status']")" = draft

draft="$(lapi POST /api/v1/real-estate/properties "{\"title\":\"$DRAFT_TITLE\",\"address\":\"Calle Borrador 2, Madrid\",\"deal_type\":\"sale\",\"price\":99000,\"currency\":\"EUR\"}")"
DRAFT_REF="$(echo "$draft" | json_field "['reference']")"
log "draft-only property reference=$DRAFT_REF"

# --- 2. borradores fuera del catálogo ---------------------------------------------
log "== 2. borradores"
sync >/dev/null || true
check "draft: test property not imported while draft" test "$(asset_count_for "$REF")" = 0
check "draft: draft-only property not imported" test "$(asset_count_for "$DRAFT_REF")" = 0
check "draft: not in public catalog API" not in_catalog_api "$TITLE"

# --- 3. publicación ---------------------------------------------------------------
log "== 3. publicación"
lapi POST "/api/v1/real-estate/properties/$PROP_ID/transition/available" >/dev/null
public_code="$(dc exec -T liberu-app curl -s -o /dev/null -w '%{http_code}' "http://localhost/api/v1/public/properties/$PROP_ID")"
check "publish: Liberu public API exposes it (HTTP $public_code)" test "$public_code" = 200
sync >/dev/null
check "publish: exactly one PWB asset for $REF" test "$(asset_count_for "$REF")" = 1
check "publish: one visible sale listing" test "$(visible_listing_count_for "$REF")" = 1
check "publish: listed in catalog API" in_catalog_api "$TITLE"
check "publish: listed on catalog page /es/buy" in_catalog_html "$TITLE"
SLUG="$(slug_for "$REF")"
detail_code="$(catalog_code "/es/properties/for-sale/$SLUG/x")"
check "publish: detail page HTTP 200 (got $detail_code)" test "$detail_code" = 200
check "draft-only property still absent after publishing the other" test "$(asset_count_for "$DRAFT_REF")" = 0

# --- 4. reintento idempotente -----------------------------------------------------
log "== 4. reintento"
assets_mid="$(pwb_sql 'SELECT COUNT(*) FROM pwb_realty_assets')"
listings_mid="$(pwb_sql 'SELECT COUNT(*) FROM pwb_sale_listings')"
summary="$(sync)"
check "retry: run reports $REF unchanged" grep -q "\"unchanged\":\[[^]]*\"$REF\"" <<<"$summary"
check "retry: no new assets" test "$(pwb_sql 'SELECT COUNT(*) FROM pwb_realty_assets')" = "$assets_mid"
check "retry: no new listings" test "$(pwb_sql 'SELECT COUNT(*) FROM pwb_sale_listings')" = "$listings_mid"
check "retry: one sync record for $REF" test "$(pwb_sql "SELECT COUNT(*) FROM pwb_external_sync_records WHERE external_reference = '$REF'")" = 1

# --- 5. cambio de precio y fotos ---------------------------------------------------
log "== 5. precio y fotos"
lapi PATCH "/api/v1/real-estate/properties/$PROP_ID" '{"price":239000}' >/dev/null
p1="$(put_photo "facade-$RUN_ID" 0x3366CC)"; p2="$(put_photo "living-$RUN_ID" 0xCC9933)"
m1="$(lapi POST /api/v1/real-estate/media-and-documents "{\"kind\":\"photo\",\"path\":\"$p1\",\"property_id\":$PROP_ID,\"title\":\"Fachada\",\"sort_order\":1}")"
m2="$(lapi POST /api/v1/real-estate/media-and-documents "{\"kind\":\"photo\",\"path\":\"$p2\",\"property_id\":$PROP_ID,\"title\":\"Salón\",\"sort_order\":2}")"
M1_ID="$(echo "$m1" | json_field "['id']")"
log "Liberu media ids: $M1_ID $(echo "$m2" | json_field "['id']")"
sync >/dev/null
check "price: PWB price is 239000.00 EUR" test "$(price_cents_for "$REF")" = 23900000
check "photos: 2 photos in PWB" test "$(photo_count_for "$REF")" = 2
check "price: catalog detail shows the new price" page_matches "/es/properties/for-sale/$SLUG/x" '239[.,]000'
blob_ok="$(dc exec -T pwb-web bundle exec rails runner "a = Pwb::RealtyAsset.find_by(reference: '$REF'); puts a.prop_photos.all? { |p| p.image.attached? && p.image.download.bytesize > 1000 }" 2>/dev/null | tail -n1)"
check "photos: stored in PWB's own storage and readable" test "$blob_ok" = true
summary="$(sync)"
check "photos: retry downloads nothing" grep -q '"photos_added":0' <<<"$summary"

# --- 6. sustitución de una foto ------------------------------------------------------
log "== 6. cambio de foto"
lapi DELETE "/api/v1/real-estate/media-and-documents/$M1_ID" >/dev/null
p3="$(put_photo "kitchen-$RUN_ID" 0x339966)"
lapi POST /api/v1/real-estate/media-and-documents "{\"kind\":\"photo\",\"path\":\"$p3\",\"property_id\":$PROP_ID,\"title\":\"Cocina\",\"sort_order\":3}" >/dev/null
summary="$(sync)"
check "photos: replaced one (1 added, 1 removed)" grep -q '"photos_added":1,"photos_removed":1' <<<"$summary"
check "photos: still 2 photos" test "$(photo_count_for "$REF")" = 2
check "photos: new caption present" test "$(pwb_sql "SELECT COUNT(*) FROM pwb_prop_photos p JOIN pwb_realty_assets a ON a.id = p.realty_asset_id WHERE a.reference = '$REF' AND p.description = 'Cocina'")" = 1

# --- 7. retirada ----------------------------------------------------------------------
log "== 7. retirada"
lapi POST "/api/v1/real-estate/properties/$PROP_ID/transition/withdrawn" >/dev/null
sync >/dev/null
check "withdraw: no visible listing" test "$(visible_listing_count_for "$REF")" = 0
check "withdraw: gone from catalog API" not in_catalog_api "$TITLE"
check "withdraw: gone from /es/buy" not in_catalog_html "$TITLE"
detail_code="$(catalog_code "/es/properties/for-sale/$SLUG/x")"
check "withdraw: detail page no longer served (HTTP $detail_code)" test "$detail_code" != 200
api_show="$(catalog_code "/api_public/v1/es/properties/$SLUG")"
log "INFO  public API show for the withdrawn slug answers HTTP $api_show (see README: known PWB behaviour)"
check "withdraw: record marked withdrawn, asset kept (no deletion)" test "$(pwb_sql "SELECT state FROM pwb_external_sync_records WHERE external_reference = '$REF'")" = withdrawn

# --- 8. panels restricted ---------------------------------------------------------------
log "== 8. acceso a paneles"
code="$(catalog_code /site_admin)"
check "panels: PWB /site_admin requires auth (HTTP $code)" test "$code" = 401
code="$(curl -sS -o /dev/null -w '%{http_code}' "${CURL_TLS[@]}" --resolve "${LIBERU_HOST}:443:127.0.0.1" "https://${LIBERU_HOST}/admin")"
check "panels: Liberu /admin requires auth (HTTP $code)" test "$code" = 401
code="$(curl -sS -o /dev/null -w '%{http_code}' "${CURL_TLS[@]}" --resolve "${LIBERU_HOST}:443:127.0.0.1" "https://${LIBERU_HOST}/storage/$p2")"
check "panels: Liberu photo files not public (HTTP $code)" test "$code" = 401
code="$(catalog_code /es/buy)"
check "catalog: public page open (HTTP $code)" test "$code" = 200

assets_after="$(pwb_sql 'SELECT COUNT(*) FROM pwb_realty_assets')"
log "assets before=$assets_before after=$assets_after (expected +1)"
check "overall: exactly one new PWB asset for the whole run" test "$assets_after" = "$((assets_before + 1))"

dc exec -T -u www-data liberu-app php artisan tinker --execute='\Laravel\Sanctum\PersonalAccessToken::where("name", "e2e-'"$RUN_ID"'")->delete();' >/dev/null || true

log "RESULT: $PASS passed, $FAIL failed  (reference $REF, draft $DRAFT_REF)  log: $LOG"
[ "$FAIL" = 0 ]
