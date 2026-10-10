#!/usr/bin/env bash
# Apply the latest repo changes (config, compose, image versions) and the latest static site.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR"

git pull --ff-only
set -a; . ./.env; set +a
git -C "${PORTFOLIO_DIR:-/srv/portfolio}" pull --ff-only

docker network inspect edge >/dev/null 2>&1 || docker network create edge >/dev/null
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f >/dev/null
docker compose ps
