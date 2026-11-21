#!/usr/bin/env bash
# Lets the panel READ the company mailbox (info@clarto.es) by IMAP for «Correo entrante». Read-only: the panel never
# marks messages as read, moves, deletes or answers them. The password is typed here, on the server, and only stored
# in .env (mode 600); it is never printed.
#
#   scripts/set-imap.sh info@clarto.es [imap.hostinger.com] [993]   # then type the mailbox password
#   scripts/set-imap.sh --test                                       # connect, open the inbox read-only, count messages
#   scripts/set-imap.sh --off                                        # forget the mailbox
#
# Then, in the panel: Correo entrante → Ajustes → «Leer el buzón» (and the owner of each area).
source "$(dirname "$0")/lib.sh"
require_env_file

set_env() { # set_env KEY VALUE (replace or append, value kept literal)
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"; grep -v "^${key}=" "$BUNDLE_DIR/.env" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$BUNDLE_DIR/.env"; rm -f "$tmp"; chmod 600 "$BUNDLE_DIR/.env"
}

imap_test() {
  dc exec -T -u www-data liberu-app php artisan tinker --execute='
    try { $b = App\InboundMail\InboundMails::connect(); $i = $b->examine(config("correo-entrante.folder", "INBOX")); $b->logout();
      echo "IMAP OK: ".$i["exists"]." mensajes en la bandeja (no se ha modificado nada)".PHP_EOL;
    } catch (Throwable $e) { echo "IMAP ERROR: ".$e->getMessage().PHP_EOL; }' 2>&1 | grep -E "IMAP (OK|ERROR)" | head -1
}

case "${1:-}" in
  --test) imap_test; exit 0 ;;
  --off)
    for k in MAIL_IN_HOST MAIL_IN_PORT MAIL_IN_USERNAME MAIL_IN_PASSWORD; do set_env "$k" ""; done
    sed -i '/^MAIL_IN_[A-Z_]*=$/d' "$BUNDLE_DIR/.env"
    dc up -d liberu-app liberu-worker liberu-scheduler >/dev/null; log "mailbox removed: «Correo entrante» stops reading"; exit 0 ;;
esac

user="${1:?usage: set-imap.sh <mailbox> [host] [port]}"
host="${2:-imap.hostinger.com}" port="${3:-993}"
[ -t 0 ] || die "run it in an interactive terminal: the password is read from the keyboard"
read -r -s -p "Password for $user (not shown): " pass; echo
[ -n "$pass" ] || die "empty password"
case "$pass" in *"'"*) die "the password contains a single quote, which .env cannot hold literally; change it in Hostinger" ;; esac

set_env MAIL_IN_HOST "$host"; set_env MAIL_IN_PORT "$port"
set_env MAIL_IN_USERNAME "$user"
set_env MAIL_IN_PASSWORD "'$pass'"   # single quotes: compose does not interpolate $ in them
unset pass
dc up -d --force-recreate liberu-app liberu-worker liberu-scheduler >/dev/null
log "panel reads $user on $host:$port (read-only). Checking…"
sleep 5; imap_test
