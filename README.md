Shopware Docker stack
=====================

Docker Compose stack for a Shopware 6 store, usable for local development and
for simple production deployments (a single server). Maintained by
[BillMySales](https://www.billmysales.com).

| Component  | Image                                                        | Default version    |
|------------|--------------------------------------------------------------|--------------------|
| Web proxy  | `caddy:<ver>-alpine` (TLS, site address)                     | 2.11               |
| Shopware   | built from `image/` on `ghcr.io/shopware/docker-base:<php>-frankenphp` | 6.7.14.2 / PHP 8.5 |
| Database   | `mariadb`                                                    | 12.3 (LTS)         |
| Mailpit    | `axllent/mailpit` (optional, dev)                            | v1.31              |

It follows [Shopware's Docker guide](https://developer.shopware.com/docs/guides/hosting/installation-updates/docker.html):
the project is created and built with `shopware-cli` at image build time and
copied into Shopware's official runtime image, which is rebuilt daily with the
latest PHP patch release. That image uses FrankenPHP (Caddy with embedded PHP,
one process), as Shopware recommends. The code is immutable; only Shopware's
data directories are volumes. A separate Caddy container in front handles TLS
and the public address, like in the other stacks. Shopware 6.7.14.2 supports
PHP 8.2 to 8.5.

Why FrankenPHP and not the image's PHP-FPM variant: with FPM, a separate web
server needs the files, so the code would have to be copied into a shared
volume; FrankenPHP serves it straight from the image, which stays immutable.

Requirements
------------

- Docker Engine 24+ with the Compose v2 plugin (`docker compose`, 2.24+).
- About 1 GB of RAM for the whole stack.
- Development: ports 8105, 8405 and 8025 free on the host.
- Production: a server with ports 80 and 443 reachable, and a DNS record for
  the store's domain pointing to it.
- The first `up` builds the image (about a minute; it downloads Shopware with
  Composer). The project is always created inside Docker: on a macOS bind
  mount (case-insensitive file system) Composer breaks packages like
  `symfony/intl`.

Quick start (development)
-------------------------

```shell
cp .env.dev.example .env
docker compose up -d
docker compose logs -f setup   # wait for "==> Done"
```

- Store: http://localhost:8105
- Administration: http://localhost:8105/admin (user `admin`, password `admin12345`)
- Mailpit (every email the store sends): http://localhost:8025

Production
----------

```shell
cp .env.prod.example .env
# Fill in SW_URL, SITE_ADDRESS, APP_SECRET, INSTANCE_ID, DB_PASSWORD,
# DB_ROOT_PASSWORD, SW_ADMIN_PASSWORD and SW_ADMIN_EMAIL.
# Recommended: the SMTP_* values (without SMTP_HOST no emails are sent).
docker compose up -d
```

- With `SITE_ADDRESS` set to the domain, Caddy gets a Let's Encrypt certificate
  and renews it automatically (certificates live in the `caddy_data` volume).
- Behind an existing Traefik (no host ports), use `overrides/traefik.yaml`
  (see [Overrides](#overrides)).
- Compose refuses to start while a required value is missing.
- Configure SMTP (recommended, not required): without `SMTP_HOST` no emails
  are sent (the image has no local mail server).
- `DB_PASSWORD` goes into `DATABASE_URL`: use URL-safe characters
  (`openssl rand -hex 24`).
- Rebuild regularly to get PHP and OS security fixes:
  `docker compose build --pull && docker compose up -d`.
- The `backup` profile is enabled by default in the production template.

Services
--------

| Service     | Profile   | Role                                                           |
|-------------|-----------|----------------------------------------------------------------|
| `db`        |           | MariaDB, data in the `db_data` volume.                         |
| `setup`     |           | One-shot job (`scripts/setup.sh`), runs on every `up`.         |
| `shopware`  |           | Shopware (FrankenPHP, plain HTTP on :8000, internal).          |
| `worker`    |           | Message queue worker (`messenger:consume async low_priority`). |
| `scheduler` |           | Scheduled tasks (`scheduled-task:run`).                        |
| `caddy`     |           | TLS and public address, the only published ports (80, 443).   |
| `backup`    | `backup`  | DB dump + private files and media on a schedule.               |
| `mailpit`   | `mailpit` | Development SMTP server that catches all mail.                 |
| `console`   | `tools`   | Shopware's `bin/console`, not started by `up`.                 |

Volumes (Shopware's writable directories): `files` (private files, e.g.
invoices), `theme` (compiled theme), `media`, `thumbnail`, `sitemap`; plus
`db_data`, `caddy_data`, `caddy_config` and `backups`.

The administration's browser-based worker is disabled
(`image/config/packages/zz-stack.yaml`): background jobs run in `worker`.

### What `setup` does

- If the URL changed, moves the storefront sales channel to `SW_URL`
  (`sales-channel:replace:url`) — before the deployment helper, which would
  otherwise create a second storefront for the new URL.
- Runs Shopware's deployment helper (`vendor/bin/shopware-deployment-helper run`):
  - Empty database: installs Shopware (`SW_LOCALE`, `SW_CURRENCY`), creates the
    admin user and the storefront sales channel, assigns the theme.
  - Installed: runs the migrations when the image's Shopware version changed
    (`system:update:finish`), installs/activates plugins found in
    `custom/plugins`, compiles the theme.
- When `SMTP_HOST` is set, writes the mailer settings from `SMTP_*`.
- Once: shop name (`SW_SHOP_NAME`); stores `core.dockerStack.initialized`, so
  later changes in the administration are kept.

Upgrading Shopware: back up, set `SW_VERSION`, then
`docker compose up -d --build` (new image; `setup` migrates the database).

Common commands
---------------

```shell
docker compose ps                                  # every service "healthy", setup "Exited (0)"
docker compose logs -f shopware worker             # web and queue logs
docker compose run --rm console plugin:list        # any bin/console command
docker compose run --rm console cache:clear
docker compose exec db mariadb -u shopware -p shopware   # SQL shell
docker compose down                                # stop, keep data
docker compose down -v                             # stop and DELETE all data
```

Backups
-------

With the `backup` profile, the `backup` service writes
`<timestamp>-db.sql.gz` and `<timestamp>-files.tar.gz` (private files and
media; theme, thumbnails and sitemaps can be regenerated) to the `backups`
volume (or `./data/backups` with `overrides/local-dirs.yaml`) at start and then
every `BACKUP_INTERVAL_HOURS`, and deletes files older than
`BACKUP_KEEP_DAYS`. Files are readable by their owner only.

```shell
docker compose run --rm --no-deps backup now                  # back up now
docker compose run --rm --no-deps backup list                 # list timestamps
docker compose stop shopware worker scheduler       # recommended while restoring
docker compose run --rm --no-deps backup restore <timestamp>  # restore DB and files
docker compose start shopware worker scheduler
docker compose run --rm console cache:clear
docker compose run --rm console media:generate-thumbnails   # if needed
```

`--no-deps` keeps the command from starting `setup` first (with damaged
data `setup` fails and the restore would never run); the database must
be running (`docker compose up -d db` if the stack is down).

Overrides
---------

Optional compose files in `overrides/`, enabled with `COMPOSE_FILE` in `.env`
(several are combined with `:`). Each file documents its variables.

```shell
COMPOSE_FILE=compose.yaml:overrides/traefik.yaml:overrides/local-dirs.yaml
```

| File                         | Purpose                                                           |
|------------------------------|-------------------------------------------------------------------|
| `overrides/traefik.yaml`     | Publish through an existing Traefik on a shared external network: |
|                              | no host ports, Traefik terminates TLS (`TRAEFIK_HOST`, ...).      |
| `overrides/local-dirs.yaml`  | Database, Shopware's data directories, Caddy and backups in local |
|                              | directories (`DATA_DIR`, default `./data`).                       |
| `overrides/plugin.yaml`      | Mount a plugin into `custom/plugins` from a local directory,      |
|                              | editable live; `setup` installs and activates it                  |
|                              | (`PLUGIN_PATH`, `PLUGIN_NAME`).                                   |

A local `compose.override.yaml` (gitignored) is also loaded automatically by
Docker Compose, for changes specific to one machine.

Configuration
-------------

Every variable is documented in `.env.prod.example`. Main groups:

- **Site and network**: `SW_URL`, `SITE_ADDRESS`, `HTTP_BIND`, `HTTP_PORT`,
  `HTTPS_PORT`.
- **Secrets and credentials** (required): `APP_SECRET`, `INSTANCE_ID`,
  `DB_PASSWORD`, `DB_ROOT_PASSWORD`, `SW_ADMIN_PASSWORD`, `SW_ADMIN_EMAIL`;
  `SW_ADMIN_USER`. The `SW_ADMIN_*` values are only used by the installer:
  changing them later doesn't change the account.
- **Store** (first install only): `SW_SHOP_NAME`, `SW_LOCALE` (`en-GB` or
  `de-DE`; other languages need a language pack plugin), `SW_CURRENCY`
  (default `CLP`).
- **Versions**: `SW_VERSION`, `PHP_VERSION`, `SW_IMAGE`, `CADDY_VERSION`,
  `MARIADB_VERSION`.
- **Shopware / PHP**: `PHP_DISPLAY_ERRORS`, `LOG_LEVEL`, `SW_HTTP_CACHE`,
  `PHP_MEMORY_LIMIT`, `UPLOAD_MAX_SIZE` (PHP and Caddy), `WORKER_TIME_LIMIT`,
  `WORKER_MEMORY_LIMIT`.
- **Mail**: `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`,
  `SMTP_PASSWORD`, `SMTP_FROM` (shop email address).
- **Resources and logs**: `*_MEMORY_LIMIT` per service, `LOG_MAX_SIZE`,
  `LOG_MAX_FILE` (Docker log rotation).

Files:

| File                                   | Purpose                                                    |
|----------------------------------------|------------------------------------------------------------|
| `image/Dockerfile`                     | Shopware image (shopware-cli build + docker-base runtime). |
| `image/config/packages/zz-stack.yaml`  | Admin worker off, logs to stderr.                          |
| `config/caddy/Caddyfile`               | TLS, public address, security headers, proxy to Shopware.  |
| `scripts/setup.sh`                     | Deployment helper, URL, SMTP, initial settings.            |
| `scripts/storefront-url.php`           | Current storefront URL (URL changes).                      |
| `scripts/backup.sh`                    | Backups and restore.                                       |

Notes:

- Shopware's web rules (front controller, static media/theme/bundles) are in
  the runtime image; the root is `public/`, so nothing outside it is reachable.
- `SYMFONY_TRUSTED_PROXIES=private_ranges` makes Shopware trust Caddy's
  `X-Forwarded-*` headers (HTTPS links behind the proxy). Caddy drops a
  client's `X-Forwarded-Port` (it doesn't reset that one like the others),
  so URLs can't get a forged port.
- Logs go to stderr (`docker compose logs`) at `LOG_LEVEL` (default `warning`;
  `info` floods the log with deprecation notices, the development template
  uses `notice`).
- Search uses the database; OpenSearch is not included.
- From inside the containers, the host machine is reachable as
  `host.docker.internal`.

Security
--------

- No default secrets: compose fails if the required values are missing. The
  development template uses public values; never use it on a server.
- `APP_SECRET` and `INSTANCE_ID` are required because the project's `.env`
  baked into the image contains generated values: never rely on them.
- PHP errors are never shown to visitors (`display_errors` off unless
  `PHP_DISPLAY_ERRORS=On`, only in the development template).
- Production mode (`APP_ENV=prod`), immutable code in the image, only
  `public/` served, PHP version not exposed, security headers.
- Only Caddy (and Mailpit in development) publishes ports; the database and
  Shopware are internal. `HTTP_BIND` defaults to `127.0.0.1`.
- Not included: a web application firewall, login rate limiting, or off-site
  backup copies.

Validation
----------

What was checked for this stack (2026-09-24):

- Clean start (`down -v` + `up -d`, image already built) in about 35 s: every
  service `healthy`, `setup` `Exited (0)`; a second run makes no changes.
- Storefront, administration, health check `200`; private paths `404`;
  admin API login; CLP as default currency.
- End to end: a customer registered through the Store API → registration
  email queued → processed by `worker` → delivered to Mailpit.
- A setting changed in the administration survives `setup`; changing `SW_URL`
  moves the storefront (and back) without creating extra sales channels.
- Upgrade: 6.7.14.1 installed, then `SW_VERSION=6.7.14.2` → the deployment
  helper runs `system:update:finish`, data kept.
- Backup, retention and restore.
- HTTPS with `SITE_ADDRESS=localhost` (Caddy internal CA, HTTP/2), HTTPS links
  through the proxy; production defaults.
- Overrides: Traefik v3.6 routing with no host ports, local directories
  (including backups), a plugin mounted, installed and activated by `setup`.
- Not tested: issuing a real Let's Encrypt certificate (needs a public domain).

Resource usage
--------------

Idle, after a few requests: Caddy ~15 MiB, Shopware ~160 MiB, worker ~175 MiB,
scheduler ~140 MiB, MariaDB ~210 MiB (about 700 MiB in total).

License
-------

[MIT](LICENSE).
