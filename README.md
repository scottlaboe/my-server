# my-server

Docker Compose setup for scottlaboe.com: Caddy (automatic HTTPS), WordPress, and MariaDB.
The static site lives in its own repo ([scottlaboe.com](https://github.com/scottlaboe/scottlaboe.com))
and is cloned onto the server by the bootstrap script.

| Hostname | Served by |
|---|---|
| `scottlaboe.com`, `www.` | Static site from `/srv/portfolio` |
| `blog.scottlaboe.com` | WordPress (PHP-FPM + MariaDB) |

## Set up a new server

On a fresh Ubuntu 24.04 instance (t4g.micro / 1 GB is enough):

```bash
curl -fsSL https://raw.githubusercontent.com/scottlaboe/my-server/main/scripts/bootstrap.sh | sudo bash
```

This adds swap, installs Docker and the AWS CLI, clones this repo to `/opt/my-server` and the
static site to `/srv/portfolio`, generates random database passwords in `.env`, installs cron jobs,
and starts everything. It is safe to re-run.

Then restore your data (the database is the only thing that needs preserving):

```bash
cd /opt/my-server
scripts/restore.sh /path/to/wordpress.sql.gz /path/to/wp-content.tar.gz
```

## Day to day

| Task | Command |
|---|---|
| Apply repo changes / update images | `scripts/deploy.sh` |
| Status | `docker compose ps` |
| Logs | `docker compose logs -f caddy` |
| WP-CLI | `docker compose run --rm wpcli <command>` |
| Static site updates | Automatic: the server pulls the site repo every 5 minutes |

Edit config in `config/`, commit, push, then run `scripts/deploy.sh` on the server.
To try changes first, run `docker compose up -d` locally with `CADDY_GLOBAL_OPTS=local_certs` in `.env`.

## Backups

`scripts/backup.sh` runs every 15 minutes from cron but only uploads to S3 when a post, page,
attachment, or comment has changed (plus a forced backup every 7 days). Set `BACKUP_BUCKET` in
`.env`; the instance's IAM role provides S3 access, so no keys are stored on disk.
Retention is handled by an S3 lifecycle rule on the bucket, not by this repo.

## Testing before pointing DNS here

Set `CADDY_GLOBAL_OPTS=local_certs` in `.env` and run `docker compose up -d` to get self-signed
certificates, then test with `curl -k --resolve blog.scottlaboe.com:443:<server-ip> https://blog.scottlaboe.com/`.
Clear the setting for production so Let's Encrypt certificates are issued automatically.

## Secrets

Nothing sensitive is committed. `.env` is gitignored and generated on the server.
