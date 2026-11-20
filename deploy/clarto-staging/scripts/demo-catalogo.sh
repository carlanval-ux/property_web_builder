#!/usr/bin/env bash
# Publishes two clearly fictitious listings so the website preview can be browsed
# (marked "Inmueble de prueba" while CATALOGO_MODO_PRUEBAS=true). Idempotent: an
# existing demo listing (same title) is left as is. Remove them before going live:
#   scripts/demo-catalogo.sh --retirar
source "$(dirname "$0")/lib.sh"
require_env_file

MODE="${1:-publicar}"
artisan() { dc exec -T -u www-data liberu-app php artisan tinker --execute="$1" 2>/dev/null | tail -n1 | tr -d '\r'; }

# Photos: licensed website images (Unsplash, see the website's docs/design/asset-manifest.md)
WEB_IMG="$BUNDLE_DIR/src/web/public/images/clarto"
cid="$(dc ps -q liberu-app)"
docker exec -u www-data "$cid" mkdir -p /var/www/html/storage/app/public/demo
for f in inmobiliaria-wide-1600.webp valencia-wide-1600.webp patrimonio-detalle-wide-1600.webp; do
  [ -f "$WEB_IMG/$f" ] && docker cp "$WEB_IMG/$f" "$cid:/var/www/html/storage/app/public/demo/$f"
done
# Every demo photo carries a large "PRUEBA" stamp (GD, built-in font scaled up): demo-prueba-*.webp
docker exec -u www-data "$cid" php -r '
  foreach (glob("/var/www/html/storage/app/public/demo/*-wide-1600.webp") as $src) {
    $img = imagecreatefromwebp($src); $w = imagesx($img); $h = imagesy($img);
    $txt = imagecreatetruecolor(60, 16); imagesavealpha($txt, true);
    imagefill($txt, 0, 0, imagecolorallocatealpha($txt, 0, 0, 0, 127));
    imagestring($txt, 5, 3, 0, "PRUEBA", imagecolorallocate($txt, 255, 255, 255));
    $bandH = (int) ($h * 0.30); $y = (int) (($h - $bandH) / 2);
    imagefilledrectangle($img, 0, $y, $w, $y + $bandH, imagecolorallocatealpha($img, 189, 121, 104, 40));
    $tw = (int) ($bandH * 3.4); $th = (int) ($bandH * 0.85);
    imagecopyresized($img, $txt, (int) (($w - $tw) / 2), $y + (int) (($bandH - $th) / 2), 0, 0, $tw, $th, 60, 16);
    imagewebp($img, dirname($src)."/demo-prueba-".basename($src), 82);
  }'
docker exec "$cid" chown -R www-data:www-data /var/www/html/storage/app/public/demo

artisan '
use Liberu\RealEstate\Properties\Models\{Property, Region, City, District};
use Liberu\RealEstate\MediaAndDocuments\Models\MediaDocument;
use Liberu\RealEstate\Properties\Domain\PropertyStatus;
$team = \Liberu\Foundation\Organizations\Models\Team::query()->oldest()->firstOrFail();
$admin = \App\Models\User::where("email", "admin@example.com")->firstOrFail();
$r = Region::firstOrCreate(["slug" => "valencia"], ["name" => "Valencia"]);
$sag = City::firstOrCreate(["slug" => "sagunto"], ["name" => "Sagunto", "region_id" => $r->id]);
$pto = District::firstOrCreate(["slug" => "puerto-de-sagunto"], ["name" => "Puerto de Sagunto", "city_id" => $sag->id]);
$vlc = City::firstOrCreate(["slug" => "valencia-ciudad"], ["name" => "Valencia", "region_id" => $r->id]);
$ruz = District::firstOrCreate(["slug" => "ruzafa"], ["name" => "Ruzafa", "city_id" => $vlc->id]);
$demos = [
  ["title" => "Piso luminoso con terraza cerca del puerto", "deal_type" => "sale", "property_type" => "apartment", "price" => 189000, "bedrooms" => 3, "bathrooms" => 2, "area_sqft" => 96, "year_built" => 2004, "energy_rating" => "D", "city_id" => $sag->id, "district_id" => $pto->id, "lat" => 39.6667, "lng" => -0.2240,
   "features" => ["Terraza", "Ascensor", "Aire acondicionado", "Trastero"], "has_parking" => true,
   "description" => "Inmueble ficticio de demostración. Piso exterior de tres dormitorios a cinco minutos del puerto, con terraza orientada al sur, cocina equipada y plaza de garaje.\n\nTexto de ejemplo para revisar el diseño de la ficha.",
   "photos" => ["demo/demo-prueba-inmobiliaria-wide-1600.webp" => "Fachada", "demo/demo-prueba-patrimonio-detalle-wide-1600.webp" => "Salón"],
   "es" => ["summary" => "Inmueble de prueba: piso exterior de tres dormitorios con terraza a cinco minutos del puerto.", "seo_title" => "Piso de prueba con terraza en Puerto de Sagunto", "seo_description" => "Inmueble ficticio de demostración del catálogo de CLARTO."],
   "en" => ["title" => "Bright flat with a terrace near the port", "summary" => "Test listing: three-bedroom flat with a south-facing terrace, five minutes from the port.", "description" => "Fictitious demo property. Three-bedroom flat five minutes from the port, with a south-facing terrace, fitted kitchen and a parking space.

Sample text to review the listing layout.", "seo_title" => "Test flat with terrace in Puerto de Sagunto", "seo_description" => "Fictitious demo property in the CLARTO catalogue."],
   "tr" => ["title" => "Limana yakın, teraslı ve aydınlık daire", "summary" => "Deneme ilanı: limana beş dakika mesafede, güneye bakan teraslı üç yatak odalı daire.", "description" => "Kurgusal tanıtım ilanı. Limana beş dakika mesafede, güneye bakan terası, donanımlı mutfağı ve otoparkı olan üç yatak odalı daire.

İlan düzenini incelemek için örnek metin.", "seo_title" => "Puerto de Sagunto’da teraslı deneme dairesi", "seo_description" => "CLARTO kataloğunda geçici tanıtım ilanı; çevirisi örnektir."]],
  ["title" => "Apartamento reformado en Ruzafa", "deal_type" => "rent", "property_type" => "apartment", "price" => 1150, "bedrooms" => 2, "bathrooms" => 1, "area_sqft" => 68, "year_built" => 1965, "energy_rating" => "E", "city_id" => $vlc->id, "district_id" => $ruz->id, "lat" => 39.4615, "lng" => -0.3737,
   "features" => ["Amueblado", "Calefacción", "Balcón"], "has_parking" => false,
   "description" => "Inmueble ficticio de demostración. Apartamento reformado en una finca clásica de Ruzafa, amueblado y listo para entrar a vivir.\n\nTexto de ejemplo para revisar el diseño de la ficha.",
   "photos" => ["demo/demo-prueba-valencia-wide-1600.webp" => "Entorno", "demo/demo-prueba-inmobiliaria-wide-1600.webp" => "Fachada"],
   "en" => ["title" => "Renovated apartment in Ruzafa"]],
];
$out = [];
foreach ($demos as $d) {
  $p = Property::where("team_id", $team->id)->where("title", $d["title"])->first();
  if ("'"$MODE"'" === "--retirar") {
    if ($p && $p->status !== PropertyStatus::Withdrawn) { $p->forceFill(["status" => PropertyStatus::Withdrawn])->save(); }
    $out[] = ($p?->reference() ?? "-")." retirado"; continue;
  }
  $photos = $d["photos"];
  if ($p) {
    // Existing demo: publish it again and point its photos to the stamped versions.
    $p->forceFill(["status" => PropertyStatus::Available, "published_at" => $p->published_at ?? now()])->save();
    MediaDocument::where("property_id", $p->id)->where("kind", "photo")->delete();
    $n = 1;
    foreach ($photos as $path => $caption) {
      (new MediaDocument())->forceFill(["team_id" => $team->id, "property_id" => $p->id, "kind" => "photo", "path" => $path, "title" => $caption, "sort_order" => $n++, "created_by" => $admin->id])->save();
    }
  }
  if (! $p) {
    $p = new Property();
    $p->forceFill(["team_id" => $team->id, "created_by" => $admin->id, "address" => "Dirección ficticia (no se publica)",
      "title" => $d["title"], "description" => $d["description"], "property_type" => $d["property_type"], "deal_type" => $d["deal_type"],
      "price" => $d["price"], "currency" => "EUR", "bedrooms" => $d["bedrooms"], "bathrooms" => $d["bathrooms"], "area_sqft" => $d["area_sqft"],
      "year_built" => $d["year_built"], "energy_rating" => $d["energy_rating"], "features" => $d["features"], "has_parking" => $d["has_parking"],
      "region_id" => $r->id, "city_id" => $d["city_id"], "district_id" => $d["district_id"], "latitude" => $d["lat"], "longitude" => $d["lng"],
      "status" => PropertyStatus::Available, "published_at" => now()])->save();
    $n = 1;
    foreach ($d["photos"] as $path => $caption) {
      $doc = new MediaDocument();
      $doc->forceFill(["team_id" => $team->id, "property_id" => $p->id, "kind" => "photo", "path" => $path, "title" => $caption, "sort_order" => $n++, "created_by" => $admin->id])->save();
    }
  }
  if (IlluminateSupportFacadesSchema::hasTable("clarto_property_texts")) {
    foreach (["es", "en", "tr"] as $loc) {
      if (! empty($d[$loc])) { AppModelsPropertyText::updateOrCreate(["property_id" => $p->id, "locale" => $loc], $d[$loc] + ["source" => "manual"]); }
    }
  }
  $out[] = $p->reference()." ".$p->status->value;
}
echo implode(" | ", $out);'
