# my-server

Docker Compose setup for scottlaboe.com: Caddy (automatic HTTPS), WordPress, and MariaDB.
The static site lives in its own repo ([scottlaboe.com](https://github.com/scottlaboe/scottlaboe.com))
and is cloned onto the server by the bootstrap script.

| Hostname | Served by |
|---|---|
| `scottlaboe.com`, `www.` | Static site from `/srv/portfolio` |
| `blog.scottlaboe.com` | WordPress (PHP-FPM + MariaDB) |
| `homes.scottlaboe.com` | [house-hunter](https://github.com/scottlaboe/house-hunters) (separate repo and Compose project; Caddy reaches it over the shared `edge` network) |

## Set up a new server

On a fresh Ubuntu 24.04 instance (t4g.micro / 1 GB is enough) launched with the
`my-server-profile` instance profile:

```bash
curl -fsSL https://raw.githubusercontent.com/scottlaboe/my-server/main/scripts/bootstrap.sh | sudo bash
```

This adds swap, installs Docker and the AWS CLI, clones this repo to `/opt/my-server` and the
static site to `/srv/portfolio`, and installs cron jobs. Then it:

- restores `.env` from SSM `/my-server/env`, or generates one with random database passwords
  and saves it there;
- starts everything, and if the WordPress database is empty, restores the newest `db/` dump and
  `uploads/` from the backup bucket;
- installs [house-hunter](https://github.com/scottlaboe/house-hunters), cloning the private repo with
  a read-only deploy key from SSM `/house-hunter/deploy-key` (skipped if the key isn't there).

It is safe to re-run, and it never restores over existing data. Point DNS at the new server's
IP (or move the Elastic IP) and Caddy gets certificates automatically.

Only uploads are backed up from `wp-content`. Themes and plugins that don't ship with the
WordPress image have to be reinstalled.

### One-time AWS setup

Run once per AWS account, from your own computer:

```bash
BUCKET=<backup-bucket> scripts/setup-aws.sh     # with admin credentials
```

This creates the `server-admin` IAM user and policy, scoped to EC2, the backup bucket, SSM
`/my-server/*` and `/house-hunter/*`, the instance role, and the DNS zone. Its keys are saved as
the AWS CLI profile `server-admin`. The script also lets the instance role read and save
`/my-server/env`. house-hunter has its own `scripts/setup-aws.sh` for its deploy key.

### Restoring by hand

```bash
cd /opt/my-server
scripts/restore.sh --latest                                   # newest backup in S3
scripts/restore.sh /path/to/wordpress.sql.gz /path/to/wp-content.tar.gz
```

## Day to day

| Task | Command |
|---|---|
| Apply repo changes / update images | `scripts/deploy.sh` |
| Change `.env` | Edit it, then `scripts/deploy.sh` (saves it to SSM for the next server) |
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

Nothing sensitive is committed. `.env` is gitignored, generated on the server, and kept in SSM
`/my-server/env` (SecureString, last 100 versions retained) so a new server gets the same values.
