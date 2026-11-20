#!/usr/bin/env bash
# Applies the CLARTO identity to settings both apps keep in their databases
# (idempotent; run by scripts/deploy.sh after migrations).
#   - panel: site name, contact e-mail, currency, language, footer, no upstream GitHub link
#   - catalog: handled by rake pwb:clarto_staging:bootstrap (colours, fonts, logo, credit)
source "$(dirname "$0")/lib.sh"
require_env_file

dc run --rm --no-deps -T -e PANEL_BRAND="${PANEL_BRAND:-CLARTO Gestión Inmobiliaria}" liberu-app php artisan tinker --execute='
  $s = app(\Liberu\Foundation\Settings\Settings\SiteSettings::class);
  $brand = getenv("PANEL_BRAND");
  $s->site_name = $brand;
  $s->site_email = "info@clarto.es";
  $s->site_country = "España";
  $s->site_currency = "€";
  $s->site_default_language = "es";
  $s->github_url = null;
  $s->footer_copyright = "© ".date("Y")." CLARTO · Lo complejo, claro.";
  $s->save();
  echo "BRAND_OK ".$s->site_name.PHP_EOL;
' | grep '^BRAND_OK' || die "could not apply panel brand settings"
