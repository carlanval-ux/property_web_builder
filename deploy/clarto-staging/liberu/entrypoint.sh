#!/bin/sh
# Liberu container entrypoint (CLARTO staging). Migrations and seeds are NOT run
# here: scripts/deploy.sh runs them once per deploy, so the web, worker and
# scheduler containers never race each other on schema changes.
set -e

cd /var/www/html

mkdir -p storage/app/public storage/framework/sessions storage/framework/views storage/framework/cache storage/logs
chown -R www-data:www-data storage/app storage/framework storage/logs bootstrap/cache

[ -L public/storage ] || ln -s /var/www/html/storage/app/public public/storage

# SQLite database on the persistent volume (DB_DATABASE). WAL lets the web,
# worker and scheduler containers read while one of them writes; the mode is
# stored in the database file, so setting it once is enough.
if [ "${DB_CONNECTION:-}" = "sqlite" ] && [ -n "${DB_DATABASE:-}" ]; then
  mkdir -p "$(dirname "$DB_DATABASE")"
  [ -f "$DB_DATABASE" ] || touch "$DB_DATABASE"
  chown -R www-data:www-data "$(dirname "$DB_DATABASE")"
  runuser -u www-data -- php -r '$p = new PDO("sqlite:" . getenv("DB_DATABASE")); $p->exec("PRAGMA journal_mode=WAL");'
fi
runuser -u www-data -- php artisan optimize --quiet || echo "warning: artisan optimize failed" >&2

if [ "$1" = "php" ]; then
  # worker / scheduler / one-off artisan commands run as the web user,
  # arguments passed through untouched (no shell re-parsing)
  exec runuser -u www-data -- "$@"
fi
exec "$@"
