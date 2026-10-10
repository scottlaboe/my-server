#!/usr/bin/env bash
# Back up the WordPress database (and uploads) to S3, but ONLY when content changed.
# Runs from cron every 15 minutes; exits immediately when nothing is new.
#
# "Changed" = a post/page/attachment/comment was added or modified. Revisions, autosaves,
# transients and options (which churn constantly) are ignored. A backup is also forced
# if the last one is older than FORCE_DAYS, as a safety net for settings-only changes.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-/var/lib/my-server-backup}"
FORCE_DAYS="${FORCE_DAYS:-7}"
cd "$APP_DIR"
set -a; . ./.env; set +a

[ -n "${BACKUP_BUCKET:-}" ] || { echo "BACKUP_BUCKET not set; skipping"; exit 0; }
mkdir -p "$STATE_DIR"

fingerprint() {
  docker compose exec -T db sh -c 'mariadb -N -uroot -p"$MARIADB_ROOT_PASSWORD" wordpress -e "
    SELECT CONCAT(
      (SELECT COUNT(*) FROM wp_posts WHERE post_type NOT IN (\"revision\",\"auto-draft\",\"customize_changeset\",\"oembed_cache\") AND post_status<>\"auto-draft\"), \"-\",
      IFNULL((SELECT MAX(post_modified_gmt) FROM wp_posts WHERE post_type NOT IN (\"revision\",\"auto-draft\",\"customize_changeset\",\"oembed_cache\") AND post_status<>\"auto-draft\"), \"\"), \"-\",
      (SELECT COUNT(*) FROM wp_comments), \"-\",
      IFNULL((SELECT MAX(comment_date_gmt) FROM wp_comments), \"\"))"'
}

current="$(fingerprint)"
last="$(cat "$STATE_DIR/fingerprint" 2>/dev/null || true)"
stamp_file="$STATE_DIR/last_backup"
age_days=999
[ -f "$stamp_file" ] && age_days=$(( ( $(date +%s) - $(stat -c %Y "$stamp_file") ) / 86400 ))

if [ "$current" = "$last" ] && [ "$age_days" -lt "$FORCE_DAYS" ]; then
  exit 0
fi

ts="$(date -u +%Y-%m-%dT%H%M%SZ)"
tmp="$(mktemp /tmp/wpdb.XXXXXX.sql.gz)"
trap 'rm -f "$tmp"' EXIT

docker compose exec -T db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction --skip-dump-date wordpress' | gzip > "$tmp"

# Refuse to upload an empty/failed dump (the old script had the same guard)
[ "$(stat -c %s "$tmp")" -gt 2000 ] || { echo "dump suspiciously small; aborting" >&2; exit 1; }

aws s3 cp "$tmp" "s3://${BACKUP_BUCKET}/db/wordpress-${ts}.sql.gz" --only-show-errors
uploads="$(docker volume inspect my-server_wp --format '{{ .Mountpoint }}')/wp-content/uploads"
[ -d "$uploads" ] && aws s3 sync "$uploads" "s3://${BACKUP_BUCKET}/uploads/" --only-show-errors

echo "$current" > "$STATE_DIR/fingerprint"
touch "$stamp_file"
echo "$(date -u +%FT%TZ) backup uploaded: db/wordpress-${ts}.sql.gz"
