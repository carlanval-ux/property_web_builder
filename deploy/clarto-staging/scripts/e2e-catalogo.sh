#!/usr/bin/env bash
# End-to-end check of the catalog flow: panel (Liberu) -> read-only catalog API
# -> website preview (clarto.es/inmuebles branch), with a fictitious property.
# Back office actions go through the panel's authenticated REST API (the same
# operations the team does in the panel UI); the catalog is checked over HTTPS
# on the preview host exactly as an anonymous visitor sees it.
#
#   scripts/e2e-catalogo.sh        # log in state/e2e-catalogo-<UTC>.log; exit 1 on any failure
source "$(dirname "$0")/lib.sh"
require_env_file

mkdir -p "$BUNDLE_DIR/state"
LOG="$BUNDLE_DIR/state/e2e-catalogo-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); log "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); log "FAIL  $*"; }
check() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
not() { ! "$@"; }

PREVIEW="https://${PREVIEW_HOST:-inmuebles-previa.clarto.es}"
RUN="$(date -u +%H%M%S)"
TITLE="Piso de prueba E2E ${RUN} en Puerto de Sagunto"

artisan() { dc exec -T -u www-data liberu-app php artisan tinker --execute="$1" 2>/dev/null | tail -n1 | tr -d '\r'; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); d=d.get('data', d); print($1)"; }

# --- fixtures: locations + API token (panel admin, as the team would act) ------------------
artisan '
  $r = \Liberu\RealEstate\Properties\Models\Region::firstOrCreate(["slug" => "valencia"], ["name" => "Valencia"]);
  $c = \Liberu\RealEstate\Properties\Models\City::firstOrCreate(["slug" => "sagunto"], ["name" => "Sagunto", "region_id" => $r->id]);
  \Liberu\RealEstate\Properties\Models\District::firstOrCreate(["slug" => "puerto-de-sagunto"], ["name" => "Puerto de Sagunto", "city_id" => $c->id]);
  echo "ok";' >/dev/null
IDS="$(artisan 'echo implode(",", [\Liberu\RealEstate\Properties\Models\Region::where("slug","valencia")->value("id"), \Liberu\RealEstate\Properties\Models\City::where("slug","sagunto")->value("id"), \Liberu\RealEstate\Properties\Models\District::where("slug","puerto-de-sagunto")->value("id")]);')"
IFS=, read -r REGION_ID CITY_ID DISTRICT_ID <<<"$IDS"
TOKEN="$(artisan '$u = \App\Models\User::where("email","admin@example.com")->firstOrFail(); echo $u->createToken("e2e-catalogo-'"$RUN"'")->plainTextToken;')"
[ -n "$TOKEN" ] && [ -n "$DISTRICT_ID" ] || die "fixtures failed (token or locations)"

lapi() { # METHOD PATH [JSON]
  dc exec -T liberu-app curl -sS -X "$1" "http://localhost$2" -H "Host: ${LIBERU_HOST}" \
    -H "Accept: application/json" -H "Content-Type: application/json" -H "X-Forwarded-Proto: https" \
    -H "Authorization: Bearer $TOKEN" ${3:+--data "$3"}
}
web() { curl -sS --max-time 20 "$PREVIEW$1"; }
code() { curl -sS -o /dev/null --max-time 20 -w '%{http_code}' "$PREVIEW$1"; }
in_list() { web "/inmuebles?q=E2E%20${RUN}" | grep -a -q "$1"; }
photo() { # name colour -> path on the public disk
  dc exec -T -u www-data liberu-app php -r '
    $i = imagecreatetruecolor(1600, 1200); imagefill($i, 0, 0, hexdec("'"$2"'"));
    @mkdir("storage/app/public/e2e", 0775, true); imagejpeg($i, "storage/app/public/e2e/'"$1"'.jpg", 85);' >/dev/null
  echo "e2e/$1.jpg"
}

# --- 1. alta en el panel (borrador) ------------------------------------------------------------
log "== 1. alta en el panel"
before="$(dc exec -T liberu-app curl -sS -H "X-Catalogo-Clave: ${CATALOGO_API_KEY}" http://localhost/api/v1/catalogo/inmuebles | python3 -c 'import json,sys; print(json.load(sys.stdin)["meta"]["total_publicados"])')"
created="$(lapi POST /api/v1/real-estate/properties "{\"title\":\"$TITLE\",\"address\":\"Calle Ficticia 1, 46520 Puerto de Sagunto\",\"description\":\"Inmueble ficticio para pruebas E2E del catálogo.\",\"internal_notes\":\"NOTA-INTERNA-$RUN\",\"property_type\":\"apartment\",\"deal_type\":\"sale\",\"price\":250000,\"currency\":\"EUR\",\"bedrooms\":3,\"bathrooms\":2,\"area_sqft\":95,\"region_id\":$REGION_ID,\"city_id\":$CITY_ID,\"district_id\":$DISTRICT_ID,\"latitude\":39.664321,\"longitude\":-0.226789}")"
ID="$(echo "$created" | json "d['id']" 2>/dev/null)"; REF="$(echo "$created" | json "d['reference']" 2>/dev/null)"
[ -n "$ID" ] || { log "panel answered: $created"; die "could not create the property"; }
log "property id=$ID ref=$REF"
check "alta: nace como borrador" test "$(echo "$created" | json "d['status']")" = draft

# --- 2. borrador fuera del catálogo --------------------------------------------------------------
log "== 2. borrador"
check "borrador: no aparece en el listado" not in_list "$REF"
slug_guess="piso-venta-puerto-de-sagunto-${REF,,}"
check "borrador: su ficha da 404" test "$(code "/inmuebles/$slug_guess")" = 404

# --- 3. publicar -----------------------------------------------------------------------------------
log "== 3. publicar"
lapi POST "/api/v1/real-estate/properties/$ID/transition/available" >/dev/null
check "publicar: aparece en el listado" in_list "$REF"
SLUG="$(web "/inmuebles?q=E2E%20${RUN}" | grep -a -oE "/inmuebles/[a-z0-9-]+-${REF,,}" | head -n1 | sed 's#/inmuebles/##')"
check "publicar: ficha con URL propia ($SLUG)" test "$(code "/inmuebles/$SLUG")" = 200
FICHA="$(web "/inmuebles/$SLUG")"
check "ficha: marcada como «Inmueble de prueba»" grep -a -q "Inmueble de prueba" <<<"$FICHA"
check "ficha: precio 250.000 €" grep -a -Eq "250[.,]000" <<<"$FICHA"
check "ficha: zona Puerto de Sagunto" grep -a -q "Puerto de Sagunto" <<<"$FICHA"
check "ficha: «Solicitar visita» con la referencia" grep -a -q "inmueble=${REF}" <<<"$FICHA"
check "ficha: WhatsApp con la referencia" grep -a -q "wa.me/34623229779?text=[^\"]*${REF}" <<<"$FICHA"
check "ficha: noindex (anuncio de prueba)" grep -a -qi 'name="robots" content="noindex' <<<"$FICHA"
check "ficha: canónica a clarto.es" grep -a -q "rel=\"canonical\" href=\"https://clarto.es/inmuebles/$SLUG\"" <<<"$FICHA"
check "ficha: sin dirección exacta" not grep -a -q "Calle Ficticia" <<<"$FICHA"
check "ficha: sin notas internas" not grep -a -q "NOTA-INTERNA-$RUN" <<<"$FICHA"
API_JSON="$(dc exec -T liberu-app curl -sS -H "X-Catalogo-Clave: ${CATALOGO_API_KEY}" "http://localhost/api/v1/catalogo/inmuebles/$REF")"
check "API: sin dirección, notas internas ni coordenadas exactas" bash -c "! grep -a -qE 'Calle Ficticia|NOTA-INTERNA|39\\.664321|internal_notes|address' <<<'$API_JSON'"
check "API: exige la clave del servidor" test "$(curl -sS -o /dev/null -w '%{http_code}' "https://${LIBERU_HOST}/api/v1/catalogo/inmuebles")" = 401

# --- 4. reintentos sin duplicados ------------------------------------------------------------------
log "== 4. reintentos"
after_pub="$(dc exec -T liberu-app curl -sS -H "X-Catalogo-Clave: ${CATALOGO_API_KEY}" http://localhost/api/v1/catalogo/inmuebles | python3 -c 'import json,sys; print(json.load(sys.stdin)["meta"]["total_publicados"])')"
check "publicar: exactamente una ficha nueva ($before -> $after_pub)" test "$after_pub" = "$((before + 1))"
for _ in 1 2 3; do web "/inmuebles/$SLUG" >/dev/null; lapi POST "/api/v1/real-estate/properties/$ID/transition/available" >/dev/null; done
check "reintentos: la referencia sigue apareciendo una sola vez" test "$(web "/inmuebles?q=E2E%20${RUN}" | grep -a -oE "Ref\. ${REF}" | wc -l)" = 1

# --- 5. cambio de precio y fotos ---------------------------------------------------------------------
log "== 5. precio y fotos"
lapi PATCH "/api/v1/real-estate/properties/$ID" '{"price":239000}' >/dev/null
check "precio: la ficha muestra 239.000 €" bash -c "curl -sS '$PREVIEW/inmuebles/$SLUG' | grep -a -Eq '239[.,]000'"
check "precio: el listado muestra 239.000 €" bash -c "curl -sS '$PREVIEW/inmuebles?q=E2E%20${RUN}' | grep -a -Eq '239[.,]000'"
p1="$(photo "fachada-$RUN" 0x3366CC)"; p2="$(photo "salon-$RUN" 0xCC9933)"
m1="$(lapi POST /api/v1/real-estate/media-and-documents "{\"kind\":\"photo\",\"path\":\"$p1\",\"property_id\":$ID,\"title\":\"Fachada\",\"sort_order\":1}")"
lapi POST /api/v1/real-estate/media-and-documents "{\"kind\":\"photo\",\"path\":\"$p2\",\"property_id\":$ID,\"title\":\"Salón\",\"sort_order\":2}" >/dev/null
M1="$(echo "$m1" | json "d['id']" || true)"; [ -n "$M1" ] || log "media upload answered: $m1"
FICHA="$(web "/inmuebles/$SLUG")"
IMG="$(grep -a -oE "https://${LIBERU_HOST}/api/v1/catalogo/fotos/[0-9]+/960\?signature=[a-f0-9]+" <<<"$FICHA" | head -n1)"
check "fotos: la ficha muestra la galería" test -n "$IMG"
check "fotos: «Ver las 2 fotos»" grep -a -q "Ver las 2 fotos" <<<"$FICHA"
r="$(curl -sS -o /dev/null -w '%{http_code} %{content_type} %{size_download}' "$IMG")"
check "fotos: variante WebP optimizada ($r)" grep -a -qE '^200 image/webp' <<<"$r"
tampered="$(curl -sS -o /dev/null -w '%{http_code}' "${IMG%signature=*}signature=deadbeef")"
check "fotos: URL sin firma válida rechazada ($tampered)" test "$tampered" = 403
lapi DELETE "/api/v1/real-estate/media-and-documents/$M1" >/dev/null
p3="$(photo "cocina-$RUN" 0x339966)"
lapi POST /api/v1/real-estate/media-and-documents "{\"kind\":\"photo\",\"path\":\"$p3\",\"property_id\":$ID,\"title\":\"Cocina\",\"sort_order\":3}" >/dev/null
FICHA="$(web "/inmuebles/$SLUG")"
check "fotos: cambio reflejado (Cocina sí, Fachada no)" bash -c "grep -a -q 'Cocina' <<<'$FICHA' && ! grep -a -q 'alt=\"Fachada\"' <<<'$FICHA'"

# --- 6. reservar -------------------------------------------------------------------------------------
log "== 6. reservar"
lapi POST "/api/v1/real-estate/properties/$ID/transition/under_offer" >/dev/null
check "reservado: la ficha lo indica" bash -c "curl -sS '$PREVIEW/inmuebles/$SLUG' | grep -a -q 'Reservado'"
check "reservado: el listado lo indica" bash -c "curl -sS '$PREVIEW/inmuebles?q=E2E%20${RUN}' | grep -a -q 'Reservado'"
check "reservado: «Ocultar reservados» lo quita" not bash -c "curl -sS '$PREVIEW/inmuebles?q=E2E%20${RUN}&estado=disponible' | grep -a -q 'Ref. $REF'"

# --- 7. retirar --------------------------------------------------------------------------------------
log "== 7. retirar"
lapi POST "/api/v1/real-estate/properties/$ID/transition/withdrawn" >/dev/null
check "retirado: fuera del listado" not in_list "$REF"
c="$(code "/inmuebles/$SLUG")"; check "retirado: enlace directo da 404 ($c)" test "$c" = 404
check "retirado: página «ya no está publicado»" bash -c "curl -sS '$PREVIEW/inmuebles/$SLUG' | grep -a -q 'ya no está publicado'"
r="$(curl -sS -o /dev/null -w '%{http_code}' "$IMG")"
check "retirado: sus fotos dejan de servirse ($r)" test "$r" = 404

# --- 8. vista previa: sin contraseña y noindex -------------------------------------------------------
log "== 8. vista previa"
check "vista previa: abierta sin contraseña" test "$(code /inmuebles)" = 200
check "vista previa: cabecera noindex" bash -c "curl -sSI '$PREVIEW/inmuebles' | grep -a -qi '^x-robots-tag: noindex'"
check "vista previa: robots.txt bloquea todo" bash -c "curl -sS '$PREVIEW/robots.txt' | grep -a -qx 'Disallow: /'"
check "filtros: combinación con noindex" bash -c "curl -sS '$PREVIEW/inmuebles?operacion=venta&precio_max=300000' | grep -a -qi 'name=\"robots\" content=\"noindex'"
z="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$PREVIEW/inmuebles/venta/puerto-de-sagunto")"
check "zona sin contenido propio: redirige al listado ($z)" grep -a -qE '^30[127] .*/inmuebles\?' <<<"$z"

artisan '\Laravel\Sanctum\PersonalAccessToken::where("name","e2e-catalogo-'"$RUN"'")->delete(); echo 1;' >/dev/null
log "RESULT: $PASS passed, $FAIL failed (ref $REF, withdrawn; log $LOG)"
[ "$FAIL" = 0 ]
