#!/usr/bin/env bash
# Sends the panel's email (password recovery, notifications) through a real mailbox instead of the
# test mailbox. The password is typed here, on the server, and only stored in .env (mode 600).
#
#   scripts/set-smtp.sh info@clarto.es [smtp.hostinger.com] [465]   # then type the mailbox password
#   scripts/set-smtp.sh --test persona@ejemplo.com                    # send a test message
#   scripts/set-smtp.sh --off                                         # back to the test mailbox
source "$(dirname "$0")/lib.sh"
require_env_file

set_env() { # set_env KEY VALUE (replace or append, value kept literal)
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"; grep -v "^${key}=" "$BUNDLE_DIR/.env" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$BUNDLE_DIR/.env"; rm -f "$tmp"; chmod 600 "$BUNDLE_DIR/.env"
}

case "${1:-}" in
  --test)
    to="${2:?usage: set-smtp.sh --test <recipient>}"
    dc exec -T -u www-data -e TO="$to" liberu-app php artisan tinker --execute='
      Illuminate\Support\Facades\Mail::raw("Prueba de envío desde CLARTO Gestión Inmobiliaria.", fn ($m) => $m->to(getenv("TO"))->subject("Prueba de correo del panel"));
      echo "SENT".PHP_EOL;' 2>&1 | grep -E "SENT|Exception|Error" | head -3
    exit 0 ;;
  --off)
    for k in MAIL_HOST MAIL_PORT MAIL_SCHEME MAIL_USERNAME MAIL_PASSWORD MAIL_FROM_ADDRESS; do set_env "$k" ""; done
    sed -i '/^MAIL_[A-Z_]*=$/d' "$BUNDLE_DIR/.env"
    dc up -d liberu-app liberu-worker liberu-scheduler >/dev/null; log "mail back to the test mailbox"; exit 0 ;;
esac

user="${1:?usage: set-smtp.sh <mailbox> [host] [port]}"
host="${2:-smtp.hostinger.com}" port="${3:-465}"
[ -t 0 ] || die "run it in an interactive terminal: the password is read from the keyboard"
read -r -s -p "Password for $user (not shown): " pass; echo
[ -n "$pass" ] || die "empty password"
case "$pass" in *"'"*) die "the password contains a single quote, which .env cannot hold literally; change it in Hostinger" ;; esac

set_env MAIL_HOST "$host"; set_env MAIL_PORT "$port"
set_env MAIL_SCHEME "$([ "$port" = 465 ] && echo smtps || echo smtp)"
set_env MAIL_USERNAME "$user"
set_env MAIL_PASSWORD "'$pass'"   # single quotes: compose does not interpolate $ in them
set_env MAIL_FROM_ADDRESS "$user"
unset pass
dc up -d liberu-app liberu-worker liberu-scheduler >/dev/null
log "panel mail now goes through $host:$port as $user. Test it: scripts/set-smtp.sh --test <recipient>"
