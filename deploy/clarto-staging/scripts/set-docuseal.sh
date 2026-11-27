#!/usr/bin/env bash
# Connects the panel's electronic signature to DocuSeal (the group's cloud account, the same one Red Telecom uses).
# The API key and the webhook HMAC secret are typed here, on the server, and only stored in .env (mode 600); they
# are never printed. Each environment has its own pair: «pruebas» = Test Mode account in the global cloud
# (api.docuseal.com, fictitious data only), «produccion» = EU cloud account (api.docuseal.eu).
#
#   scripts/set-docuseal.sh pruebas|produccion   # type the key and the secret; selects that environment and checks
#   scripts/set-docuseal.sh --test               # read-only check: key, secret, templates of the active forms
#   scripts/set-docuseal.sh --activar            # FIRMA_DRIVER=docuseal (real sends), only if the check passes
#   scripts/set-docuseal.sh --desactivar         # FIRMA_DRIVER=simulado (the panel simulates again)
#   scripts/set-docuseal.sh --off                # forget the keys of both environments (back to simulated)
#
# Saving keys does NOT turn real sends on: Liberu keeps FIRMA_DRIVER=simulado until --activar. Saving keys again (or
# switching environment) turns real sends off until the next --activar.
source "$(dirname "$0")/lib.sh"
require_env_file

set_env() { # set_env KEY VALUE (replace or append, value kept literal)
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"; grep -v "^${key}=" "$BUNDLE_DIR/.env" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$BUNDLE_DIR/.env"; rm -f "$tmp"; chmod 600 "$BUNDLE_DIR/.env"
}
env_value() { grep -E "^$1=" "$BUNDLE_DIR/.env" | tail -1 | cut -d= -f2- || true; }
restart() { dc up -d --force-recreate liberu-app liberu-worker liberu-scheduler >/dev/null; wait_healthy liberu-app 180 >/dev/null || sleep 5; }

check() { # read-only check inside the panel (clarto:firma-comprobar); fails if something blocks real sends
  local out status=0
  out="$(liberu_artisan clarto:firma-comprobar 2>&1)" || status=$?
  printf '%s\n' "$out" | grep -E '^(OK|AVISO|ERROR) ' | sed 's/^/  /' || true
  printf '%s\n' "$out" | grep -qE '^(OK|AVISO|ERROR) ' || { printf '%s\n' "$out" | tail -5 >&2; status=1; }
  [ "$status" -eq 0 ] || die "DocuSeal no está listo (ver arriba)"
  if [ "$(env_value FIRMA_DRIVER)" = docuseal ]; then log "DocuSeal listo. Firmas reales: ACTIVADAS"
  else log "DocuSeal listo. Firmas reales: desactivadas (se activan con --activar)"; fi
}

case "${1:-}" in
  --test) check; exit 0 ;;
  --activar)
    check
    set_env FIRMA_DRIVER docuseal; restart
    log "firmas reales ACTIVADAS en el entorno $(env_value DOCUSEAL_ENVIRONMENT): «Enviar a firma» ya manda los documentos a DocuSeal"; exit 0 ;;
  --desactivar)
    set_env FIRMA_DRIVER simulado; restart; log "firmas reales desactivadas (el panel vuelve a simular)"; exit 0 ;;
  --off)
    set_env FIRMA_DRIVER simulado
    sed -i '/^DOCUSEAL_\(API_KEY\|WEBHOOK_SECRET\)_\(SANDBOX\|PROD\)=/d' "$BUNDLE_DIR/.env"
    restart; log "claves de DocuSeal borradas; el panel vuelve a simular"; exit 0 ;;
  pruebas) env=sandbox; suffix=SANDBOX; console="https://console.docuseal.com" ;;
  produccion|producción) env=production; suffix=PROD; console="https://console.docuseal.eu" ;;
  *) die "uso: set-docuseal.sh pruebas|produccion  (o --test, --activar, --desactivar, --off)" ;;
esac

[ -t 0 ] || die "ejecútalo en una terminal interactiva: la clave y el secreto se leen del teclado"
echo "Cuenta de DocuSeal de ${1}: ${console}"
read -r -s -p "Clave de la API (Consola → API → Access token; no se muestra): " key; echo
[ -n "$key" ] || die "clave vacía"
[[ "$key" =~ ^[A-Za-z0-9._-]{16,200}$ ]] || die "la clave tiene caracteres inesperados; cópiala otra vez de DocuSeal"
read -r -s -p "Secreto del webhook (Webhooks → tu webhook → Security → HMAC, «whsec_…»; no se muestra): " secret; echo
[ -n "$secret" ] || die "secreto vacío"
[[ "$secret" =~ ^[A-Za-z0-9._+/=-]{16,200}$ ]] || die "el secreto tiene caracteres inesperados; cópialo otra vez de la pestaña HMAC"
other="$([ "$suffix" = SANDBOX ] && echo PROD || echo SANDBOX)"
[ "$key" != "$(env_value "DOCUSEAL_API_KEY_$other")" ] || die "esa clave ya está guardada para el otro entorno: cada entorno es una cuenta distinta"

previous="$(env_value DOCUSEAL_ENVIRONMENT)"
[ "$(env_value FIRMA_DRIVER)" = docuseal ] && log "AVISO: las firmas reales se desactivan hasta que vuelvas a ejecutar --activar"
[ -n "$previous" ] && [ "$previous" != "$env" ] && \
  log "AVISO: cambias de entorno ($previous → $env); las solicitudes enviadas en $previous ya no se actualizan desde el panel"
set_env FIRMA_DRIVER simulado
set_env DOCUSEAL_ENVIRONMENT "$env"
set_env "DOCUSEAL_API_KEY_$suffix" "$key"
set_env "DOCUSEAL_WEBHOOK_SECRET_$suffix" "$secret"
unset key secret
restart
check
