#!/usr/bin/env bash
# Restore a WordPress database dump (and optionally wp-content) into the running stack.
#
#   scripts/restore.sh wordpress.sql[.gz] [wp-content.tar.gz]
#
# Also rewrites http:// URLs to https:// so the site works behind Caddy.
set -euo pipefail

DUMP="${1:?usage: restore.sh <dump.sql[.gz]> [wp-content.tar.gz]}"
CONTENT="${2:-}"
OLD_URL="${OLD_URL:-http://blog.scottlaboe.com}"
NEW_URL="${NEW_URL:-https://blog.scottlaboe.com}"

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR"

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
