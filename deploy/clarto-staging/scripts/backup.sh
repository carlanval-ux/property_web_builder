#!/usr/bin/env bash
# Consistent backup of the CLARTO panel: its SQLite database, its file volume
# (photos, documents) and the environment/secrets needed to use them (APP_KEY).
#
#   sudo scripts/backup.sh            -> $BACKUP_ROOT/<UTC timestamp>/
#
# Retention: BACKUP_RETENTION_DAYS (default 14). Optional off-site copy:
# BACKUP_OFFSITE_CMD (e.g. an rclone/restic command) receives the backup dir.
source "$(dirname "$0")/lib.sh"
require_env_file

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="$BACKUP_ROOT/$stamp"
umask 077
mkdir -p "$dest"
log "backup -> $dest"

# SQLite, exported online and consistently with VACUUM INTO
dc exec -T -u www-data liberu-app php -r '
  $p = new PDO("sqlite:" . getenv("DB_DATABASE"));
  @unlink("/tmp/panel-backup.sqlite");
  $p->exec("VACUUM INTO \"/tmp/panel-backup.sqlite\"");'
dc exec -T liberu-app cat /tmp/panel-backup.sqlite | gzip -9 > "$dest/liberu-db.sqlite.gz"
dc exec -T liberu-app rm -f /tmp/panel-backup.sqlite

# File volume (the live database file is excluded: it is in liberu-db.sqlite.gz)
docker run --rm -v "${COMPOSE_PROJECT}_liberu_storage:/data:ro" -v "$dest:/backup" alpine:3.22 \
  tar -C /data --exclude ./db -czf /backup/liberu_storage.tar.gz .

cp "$BUNDLE_DIR/.env" "$dest/env"
[ -d "$BUNDLE_DIR/secrets" ] && tar -C "$BUNDLE_DIR" -czf "$dest/secrets.tar.gz" secrets

count() { dc exec -T -u www-data liberu-app php -r '$p = new PDO("sqlite:" . getenv("DB_DATABASE")); echo $p->query("SELECT COUNT(*) FROM '"$1"'")->fetchColumn();' | tr -dc 0-9; }
cat > "$dest/manifest.txt" <<EOF
created_at=$stamp
pwb_ref=$PWB_REF
liberu_ref=$LIBERU_REF
liberu_properties=$(count real_estate_properties)
liberu_users=$(count users)
liberu_media=$(count real_estate_media_documents)
EOF
(cd "$dest" && sha256sum ./* > SHA256SUMS)

for f in liberu-db.sqlite.gz liberu_storage.tar.gz; do
  [ -s "$dest/$f" ] || die "backup artefact $f is empty"
done
gzip -t "$dest/liberu-db.sqlite.gz"

ln -sfn "$dest" "$BACKUP_ROOT/latest"
log "backup ok ($(du -sh "$dest" | cut -f1)): $(grep '^liberu_' "$dest/manifest.txt" | tr '\n' ' ')"

if [ -n "${BACKUP_OFFSITE_CMD:-}" ]; then
  log "off-site copy"
  $BACKUP_OFFSITE_CMD "$dest"
fi

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*Z' -mtime +"${BACKUP_RETENTION_DAYS:-14}" -print -exec rm -rf {} +
