#!/usr/bin/env bash
# Generates .env and secrets/ for a new CLARTO staging host. Idempotent: an
# existing .env is never overwritten (secrets must survive redeploys/restores).
#
#   scripts/init-env.sh [--liberu-host H] [--pwb-host H] [--tls internal]
#
# Default hosts use sslip.io on the server's public IPv4, so HTTPS works before
# CLARTO's own DNS exists. Generated credentials are written to
# secrets/credentials.txt (mode 600) — keep it out of git and out of chat.
source "$(dirname "$0")/lib.sh"

LIBERU_HOST_ARG="" PWB_HOST_ARG="" TLS_MODE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --liberu-host) LIBERU_HOST_ARG="$2"; shift 2 ;;
    --pwb-host) PWB_HOST_ARG="$2"; shift 2 ;;
    --tls) TLS_MODE_ARG="$2"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done

umask 077
mkdir -p secrets

rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

if [ -f .env ]; then
  log ".env already exists — leaving it untouched"
else
  ip="$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')"
  [ -n "$ip" ] || die "could not determine the public IPv4; pass --liberu-host/--pwb-host"
  dashed="${ip//./-}"
  LIBERU_HOST="${LIBERU_HOST_ARG:-crm.${dashed}.sslip.io}"
  PWB_HOST="${PWB_HOST_ARG:-catalogo.${dashed}.sslip.io}"
  cat > .env <<EOF
# CLARTO staging — generated $(date -u +%FT%TZ). DO NOT COMMIT.
LIBERU_HOST=${LIBERU_HOST}
PWB_HOST=${PWB_HOST}
TLS_MODE=${TLS_MODE_ARG}
PROPERTY_REFERENCE_PREFIX=CL
LIBERU_SYNC_INTERVAL=300

LIBERU_APP_KEY=base64:$(openssl rand -base64 32)
LIBERU_DB_PASSWORD=$(rand 32)
LIBERU_DB_ROOT_PASSWORD=$(rand 32)
LIBERU_ADMIN_PASSWORD=$(rand 24)

PWB_SECRET_KEY_BASE=$(openssl rand -hex 64)
PWB_DB_PASSWORD=$(rand 32)
PWB_ADMIN_EMAIL=admin@clarto.staging
PWB_ADMIN_PASSWORD=$(rand 24)

PANEL_USER=clarto
PANEL_PASSWORD=$(rand 24)
EOF
  chmod 600 .env
  log "wrote .env (hosts: ${LIBERU_HOST}, ${PWB_HOST})"
fi

# Keys added after the first install: appended once, existing values never touched.
ensure_env() { grep -q "^$1=" .env || { echo "$1=$2" >> .env; log "added $1 to .env"; }; }
ensure_env CATALOGO_API_KEY "$(rand 48)"
ensure_env CATALOGO_MODO_PRUEBAS true
ensure_env PREVIEW_HOST "inmuebles-previa.clarto.es"
ensure_env WAHA_API_KEY "$(rand 48)"            # WhatsApp (WAHA): clave de su API, solo red interna
ensure_env WAHA_WEBHOOK_HMAC_KEY "$(rand 48)"   # firma de los webhooks WAHA → panel

set -a; source .env; set +a

# Caddy basic-auth snippet for the restricted panels (bcrypt hash, never the password).
hash="$(docker run --rm caddy:2.10.2-alpine caddy hash-password --plaintext "$PANEL_PASSWORD")"
printf 'basic_auth {\n\t%s %s\n}\n' "$PANEL_USER" "$hash" > secrets/panel_auth.caddy
chmod 644 secrets/panel_auth.caddy # read by the caddy container; contains only a bcrypt hash

cat > secrets/credentials.txt <<EOF
CLARTO staging credentials ($(date -u +%FT%TZ)) — keep private.

Cuenta técnica del panel (automatizaciones/E2E, no para personas):
  https://${LIBERU_HOST}/admin/login : admin@example.com / ${LIBERU_ADMIN_PASSWORD}
  Administradores reales: scripts/panel-admin.sh <email> (enlace de un solo uso).

Basic auth de herramientas de operación (${PANEL_USER} / ${PANEL_PASSWORD}):
  buzón de pruebas  https://${LIBERU_HOST}/buzon/
  admin del catálogo https://${PWB_HOST}/site_admin (luego: ${PWB_ADMIN_EMAIL} / ${PWB_ADMIN_PASSWORD})
EOF
chmod 600 secrets/credentials.txt
log "panel auth and secrets/credentials.txt ready"
