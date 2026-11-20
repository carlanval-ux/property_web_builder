#!/usr/bin/env bash
# Consistent backup of CLARTO staging: both databases, both photo volumes and the
# environment/secrets needed to restore them (APP_KEY, SECRET_KEY_BASE).
#
#   scripts/backup.sh            -> $BACKUP_ROOT/<UTC timestamp>/
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

# Databases (online, consistent snapshots)
dc exec -T liberu-db sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --hex-blob --databases liberu' \
  | gzip -9 > "$dest/liberu-db.sql.gz"
dc exec -T pwb-db pg_dump -U pwb -d pwb_staging -Fc > "$dest/pwb-db.dump"

# Photo / upload volumes
for vol in liberu_storage pwb_storage; do
  docker run --rm -v "${COMPOSE_PROJECT}_${vol}:/data:ro" -v "$dest:/backup" alpine:3.22 \
    tar -C /data -czf "/backup/${vol}.tar.gz" .
done

# Secrets needed to make the data usable again (stays on the host, mode 600)
cp "$BUNDLE_DIR/.env" "$dest/env"
[ -d "$BUNDLE_DIR/secrets" ] && tar -C "$BUNDLE_DIR" -czf "$dest/secrets.tar.gz" secrets

# Row counts recorded at backup time, used by restore-test.sh to verify
liberu_props="$(dc exec -T liberu-db sh -c 'mysql -N -uroot -p"$MYSQL_ROOT_PASSWORD" liberu -e "SELECT COUNT(*) FROM real_estate_properties"' 2>/dev/null | tr -dc 0-9)"
pwb_assets="$(dc exec -T pwb-db psql -U pwb -d pwb_staging -tAc 'SELECT COUNT(*) FROM pwb_realty_assets' | tr -dc 0-9)"
pwb_photos="$(dc exec -T pwb-db psql -U pwb -d pwb_staging -tAc 'SELECT COUNT(*) FROM active_storage_blobs' | tr -dc 0-9)"
cat > "$dest/manifest.txt" <<EOF
created_at=$stamp
pwb_ref=$PWB_REF
liberu_ref=$LIBERU_REF
liberu_properties=$liberu_props
pwb_realty_assets=$pwb_assets
pwb_blobs=$pwb_photos
EOF
(cd "$dest" && sha256sum ./* > SHA256SUMS)

# Sanity: every artefact non-empty and the archives readable
for f in liberu-db.sql.gz pwb-db.dump liberu_storage.tar.gz pwb_storage.tar.gz; do
  [ -s "$dest/$f" ] || die "backup artefact $f is empty"
done
gzip -t "$dest/liberu-db.sql.gz"
docker run --rm -v "$dest:/b:ro" postgres:17.6-alpine pg_restore -l /b/pwb-db.dump > /dev/null

ln -sfn "$dest" "$BACKUP_ROOT/latest"
log "backup ok ($(du -sh "$dest" | cut -f1)): liberu_properties=$liberu_props pwb_realty_assets=$pwb_assets"

if [ -n "${BACKUP_OFFSITE_CMD:-}" ]; then
  log "off-site copy"
  $BACKUP_OFFSITE_CMD "$dest"
fi

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*Z' -mtime +"${BACKUP_RETENTION_DAYS:-14}" -print -exec rm -rf {} +
