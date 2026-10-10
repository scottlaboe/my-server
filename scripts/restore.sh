#!/usr/bin/env bash
# Restore a WordPress database dump (and optionally wp-content) into the running stack.
#
#   scripts/restore.sh wordpress.sql[.gz] [wp-content.tar.gz]
#   scripts/restore.sh --latest    # newest db/ dump + uploads/ from S3; exits 3 if none
#
# bootstrap.sh runs --latest automatically when the database is empty.
# Also rewrites http:// URLs to https:// so the site works behind Caddy.
set -euo pipefail

DUMP="${1:?usage: restore.sh <dump.sql[.gz]> [wp-content.tar.gz] | --latest}"
CONTENT="${2:-}"
OLD_URL="${OLD_URL:-http://blog.scottlaboe.com}"
NEW_URL="${NEW_URL:-https://blog.scottlaboe.com}"

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR"

if [ "$DUMP" = "--latest" ]; then
  set -a; . ./.env; set +a
  [ -n "${BACKUP_BUCKET:-}" ] || { echo "   BACKUP_BUCKET not set in .env; nothing to restore"; exit 3; }
  # Keys embed a UTC timestamp, so the last one listed is the newest.
  key="$(aws s3api list-objects-v2 --bucket "$BACKUP_BUCKET" --prefix db/wordpress- \
         --query 'Contents[-1].Key' --output text | tail -n1)"
  [ -n "$key" ] && [ "$key" != "None" ] || { echo "   no backups in s3://$BACKUP_BUCKET/db/"; exit 3; }
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  echo "==> Downloading s3://$BACKUP_BUCKET/$key and uploads/"
  aws s3 cp "s3://$BACKUP_BUCKET/$key" "$work/db.sql.gz" --only-show-errors
  mkdir -p "$work/uploads"
  aws s3 sync "s3://$BACKUP_BUCKET/uploads/" "$work/uploads/" --only-show-errors
  tar -czf "$work/uploads.tar.gz" -C "$work" uploads
  DUMP="$work/db.sql.gz"
  CONTENT="$work/uploads.tar.gz"
fi

docker compose up -d db wordpress

echo "==> Loading database"
case "$DUMP" in
  *.gz) gunzip -c "$DUMP" ;;
  *)    cat "$DUMP" ;;
esac | docker compose exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" wordpress'

if [ -n "$CONTENT" ]; then
  echo "==> Restoring wp-content (themes + uploads)"
  docker compose run --rm --no-deps -T --user root --entrypoint sh wordpress -c \
    'tar -xzf - -C /var/www/html/wp-content && chown -R www-data:www-data /var/www/html/wp-content' < "$CONTENT"
fi

echo "==> Rewriting URLs ${OLD_URL} -> ${NEW_URL}"
docker compose run --rm wpcli search-replace "$OLD_URL" "$NEW_URL" --all-tables --skip-columns=guid
docker compose run --rm wpcli cache flush || true
docker compose run --rm wpcli core update-db || true

echo "Done."
