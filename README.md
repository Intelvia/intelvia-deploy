# Intelvia Deployment

This is a generated, deploy-only repository for published, immutable Intelvia images. Do not maintain or directly edit generated files here: changes may be overwritten by the next synchronization from `Intelvia/intelvia`, which is the sole source of truth.

Only the checked-in Compose files, nginx templates, deploy/rollback scripts, environment examples, MariaDB configuration, and this documentation are generated. VM-local `.env` files, Docker credentials, `.deploy-state/`, `backups/`, and all parquet data are deliberately untracked and are never synchronized back to GitHub.

## Required MariaDB security material

MariaDB fails closed unless its TLS certificate and encrypted data-encryption key file are present. Before the first start, provision the five paths referenced by `MARIADB_TLS_*_HOST_FILE` and `MARIADB_ENCRYPTION_*_HOST_FILE` in `.env`:

- A private CA and a server certificate whose subject alternative names include `DNS:mariadb`.
- The server private key.
- A MariaDB file-key-management key file containing key IDs `1` and `2`, encrypted with AES-256-CBC.
- A separate high-entropy password file that decrypts that key file.

Store the CA private key outside the application host. Store or escrow the unencrypted data-encryption keys in the institution's key-management system; losing them makes the database unrecoverable. The files mounted into the VM should be owned by the deploy administrator and mode `0600`. The Compose entrypoint copies them into a MariaDB-only tmpfs before dropping privileges.

## Hospital releases

Hospital deployments use `docker-compose.yml`. `.env.example` is updated only when an operator-approved semantic release such as `v1.2.3` or `v1.2.3-beta.1` is published.

```bash
cp .env.example .env
# Configure the institution hostname, CAS, MariaDB, Sentry, and integration values.
# Set ARTIFACT_ENCRYPTION_KEY to the output of: openssl rand -base64 32
# Keep that value unchanged across releases; it decrypts existing clinical files.
chmod 600 .env
docker login docker.io
docker compose pull
docker compose up -d --wait
curl -fsS http://127.0.0.1:8080/api/health/
# Only after the replacement application is healthy:
docker compose run --rm -e MARIADB_RETIRE_LEGACY_USER=true mariadb-provision
```

Backend restarts apply Django migrations but do not recreate populated derived tables. On a first installation, run the data preparation and validation commands below before using the application.

`INTELVIA_IMAGE_TAG` must remain an explicit semantic version. Intelvia does not publish or support `latest`, `edge`, or other mutable deployment tags.

For an existing hospital installation moving from plaintext clinical files to encrypted files, set the key in `.env` and run `./upgrade-hospital-artifacts.sh` instead of the `pull` and `up` commands above. It pulls the new images, stops the application, rebuilds its clinical files from MariaDB, encrypts retained overlays and user files, validates the result, and restarts the application. The application is unavailable during this one-time conversion. If a step fails, it stays stopped; fix the cause and rerun the script before serving traffic. Never generate a replacement key for an installation that already has encrypted files. Rebuilding the clinical files requires the MariaDB data and the checked-in procedure mapping; lost encrypted files can be regenerated from those sources.

MariaDB uses the `intelvia_mariadb_data` volume because the Compose project name is fixed to `intelvia`. The parquet cache remains a separate `./backend/parquet_cache` bind mount.

After a source-data refresh, explicitly rebuild derived data and parquets:

```bash
docker compose --profile tools run --rm backend-refresh-tool poetry run python manage.py prepare_parquet_set --commit
docker compose --profile tools run --rm backend-refresh-tool poetry run python manage.py validate_parquets \
  --image-tag "$INTELVIA_IMAGE_TAG" --source-commit operator-managed --write-manifest
docker compose restart backend frontend
```

`prepare_parquet_set --commit` is synchronous and does not require a Celery worker or Redis.

Before upgrading, read the release notes for migration or data-refresh requirements. Never run `docker compose down -v`, `docker volume prune`, or another volume-deleting command against a production deployment.

## intelvia.app continuous deployment

Intelvia's own VM uses `docker-compose.intelvia-app.yml`, `deploy.sh`, and host nginx. Every validated `main` commit publishes and deploys matching frontend/backend images named `sha-<full-commit>`.

One-time VM prerequisites:

- A non-root deploy user with Docker access and narrowly scoped passwordless sudo for `nginx -t`, nginx reload, and the Intelvia nginx files.
- Docker Engine, Docker Compose, nginx, Certbot, `curl`, `flock`, and Git.
- DNS for `intelvia.app`, ports 80/443, and a valid certificate under `/etc/letsencrypt/live/intelvia.app/`.
- A clone of this deploy repository, normally `/home/deploy/intelvia-deploy`.
- A production `.env` based on `.env.intelvia-app.example`.
- `DJANGO_ENABLE_UNIT_VOLUME_FALLBACK_UPDATES=False` keeps the Blood Product
  Unit Fallbacks panel visible but read-only so the public demo dataset remains
  stable. Enable interactive recalculation only when intentionally changing
  the demo policy.
- `DJANGO_ENABLE_GUIDELINE_THRESHOLD_UPDATES=False` similarly keeps the
  Guideline Adherence Settings panel visible without allowing public-demo
  visitors to recalculate its shared dataset.
- Pull-only Docker Hub credentials stored in the GitHub production environment.
- Existing parquets copied into `parquets/sets/bootstrap` under the deployment checkout, or permission for the first deployment to run forced data preparation.

The deploy workflow requires these GitHub environment secrets:

- `PRODUCTION_DEPLOY_HOST`, `PRODUCTION_DEPLOY_PORT`, `PRODUCTION_DEPLOY_USER`
- `PRODUCTION_DEPLOY_SSH_KEY`, `PRODUCTION_DEPLOY_KNOWN_HOSTS`
- `PRODUCTION_APP_DIR`
- `PRODUCTION_DOCKERHUB_USERNAME`, `PRODUCTION_DOCKERHUB_TOKEN`

Pin `PRODUCTION_DEPLOY_KNOWN_HOSTS` out of band and keep `StrictHostKeyChecking=yes`. The VM credential needs pull access only; GitHub's existing Docker Hub credentials retain publish access.

## Blue-green and parquet behavior

The deployment script keeps one MariaDB service and switches between blue/green frontend/backend pairs on ports 8080 and 8081. Each backend mounts its base parquet set read-only at `/app/parquet_cache` and a shared writable scoped-artifact cache at `/app/scoped_artifact_cache`. The refresh worker can write only the set's `guideline-overlays/` directory, so settings updates can publish a new overlay without changing the base parquet files. Published guideline overlays are copied into the candidate set during deployment. Nginx reads `/etc/nginx/snippets/intelvia-active-upstream.conf` and is changed only after the inactive pair serves the requested frontend bundle and passes frontend and database/parquet-aware backend health checks.

Data-impacting commits are detected with `detect-data-impact.sh` and `data-impact-paths.txt`. The supported modes are:

- `auto`: rebuild only for detected data-contract changes; required for automatic main deployments.
- `force`: always refresh derived tables and stage a new parquet set.
- `reuse`: explicitly reuse the current set; manual operator override only.

New files are generated under `parquets/.staging/<image-tag>-<timestamp>` in the deployment checkout, validated, and promoted to the matching path under `parquets/sets/` only during a healthy cutover. The timestamp preserves rollback identity when an operator force-regenerates data for the same image. Each validated set includes `guideline-overlays/validation_manifest.json` with its producer, checksums, sizes, row counts, and Arrow schemas; a later regeneration removes this report until validation runs again. `manifest.json` tracks active artifact versions. The deploy refuses data preparation unless it can retain the active set plus `MIN_PARQUET_FREE_BYTES` of headroom.

The scheduled `Refresh intelvia.app production data` workflow runs daily at 02:00 UTC. It reuses the active image digests and exact deploy-package commit, then runs `refresh_demo_data --size md` before the staged blue-green cutover in `force` mode. The demo generator anchors its five-year range to the current UTC time and replaces clinical rows and provider mappings in one transaction, preserving settings, users, and saved states. Only this tool invocation enables `LOCAL INFILE`; ordinary runtime and refresh connections keep it disabled. The job rejects empty clinical tables and discharge/surgery dates older than the previous UTC day. Its encrypted rollback snapshot includes the mock source tables and provider mappings as well as derived tables, so failed preparation and immediate data rollback restore the matching source data. Hospital deployments and ordinary code deployments do not regenerate mock data. This replaces direct Celery writes into the active immutable parquet set.

Backend and frontend tags are resolved to registry digests before Compose starts a candidate. Deployment state records those digests and the exact generated deploy-repository commit so rollback never depends on a tag or an unpinned `git pull`.

Deployment state and rollback records live under `.deploy-state/`. List recorded IDs with:

```bash
ls -1 .deploy-state/history
```

Restore a recorded application/parquet pair with:

```bash
bash rollback.sh <deployment-id>
```

Rollback does not reverse Django migrations. Deployment state increments a schema generation whenever migration files change and refuses rollback to a state from another generation. It also records a security generation and refuses to reactivate images from before required TLS, application auditing, `LOCAL INFILE` controls, and encrypted clinical artifacts. A new forward deployment is required across either boundary. Application-only rollback can use any retained state in the current generations. A rollback that changes parquet data is limited to the immediately previous parquet generation because its matching SQL-derived tables are snapshotted and verified during restore.

The first deployment with encrypted artifacts creates a random `ARTIFACT_ENCRYPTION_KEY` in the VM-local `.env` if it is empty. Keep that key backed up with the deployment secrets: Django needs the same key to read existing Parquet and procedure-hierarchy files. Each hospital installation needs its own key. The upgrade regenerates the shared clinical files, encrypts retained user-specific files, and removes old readable Parquet sets after cutover. Changing or losing the key makes existing encrypted files unreadable until they are regenerated from MariaDB.

The newest `ROLLBACK_RETENTION_COUNT` successful states are retained, defaulting to five; older state files and their unreferenced parquet sets are removed together. Unused images older than seven days are pruned after a successful deployment. A rollback whose local image was pruned pulls its recorded digest again from Docker Hub.

Before mutation, `deploy.sh` writes `.deploy-state/pending.env`. Signals run the same idempotent cleanup used for command failures. If the process or host disappears, the next deployment treats `current.env` as authoritative, restores nginx and the parquet pointer, restores backed-up derived tables, removes the candidate, and then continues. Do not edit `current.env` or `pending.env` manually.

The public health endpoint validates MariaDB, global parquet schemas, and a write/delete probe in `/app/scoped_artifact_cache`. Deployment also checks the authentication mode configured in the VM-local `.env`: `DJANGO_DISABLE_LOGINS=True` must return the login-disabled access payload, while `False` must reach CAS through the redirect chain. Representative department/provider access should still be exercised through the institution's non-PHI smoke accounts when CAS is enabled.

MariaDB requires TLS for every network connection and encrypts InnoDB tablespaces, redo logs, temporary data, Aria tables, and binary logs. Both deployment paths fail closed until auditing and key management are active, existing Aria tables have been rebuilt, and every existing Intelvia InnoDB tablespace reports encrypted. Large existing databases may require a maintenance window; `MARIADB_ENCRYPTION_MIGRATION_TIMEOUT` controls the wait and defaults to six hours. The database audit records connections, grants/schema changes, and table access without copying PHI-bearing query text into the audit log.

The Django web processes use `MARIADB_APP_USER`, which has database-wide `SELECT` but can write only Django authentication/session, saved-state, exclusion, access-policy, provider-mapping, application-settings, and guideline-configuration tables. Migrations use the separate `MARIADB_MIGRATION_USER` with an explicit database-scoped schema privilege set. Celery and `backend-refresh-tool` use `MARIADB_REFRESH_USER`, which can read the database but can mutate or rebuild only the five SQL-managed derived tables, guideline refresh metadata, and guideline configuration status. Set `MARIADB_LEGACY_USER` to the prior deployment's broad application account before the first upgraded deployment. Generic hospital startup always preserves it and retires it only through the explicit post-health command above; blue-green deployment waits until cutover is committed. On the first blue-green security upgrade, MariaDB offers TLS without requiring it while the legacy backend remains active, then restarts with transport enforcement immediately after traffic moves to the TLS-verifying candidate. Failed deployment recovery restores legacy-compatible transport before restoring the old route; if that database recreation fails, it preserves the candidate route and pending journal for a safe retry. `LOAD DATA LOCAL INFILE` is disabled for all normal Django and refresh connections; an operator may explicitly set `MARIADB_TOOL_ALLOW_LOCAL_INFILE=True` only for a one-off trusted migration-tool container.

Every `/api/` response includes a server-generated `X-Request-ID`, and Django emits a JSON `intelvia.api_access` event containing the authenticated username, Intelvia role, named route, method, outcome, status, remote address, and duration. Query strings and request bodies are deliberately excluded. Set `AUDIT_TRUSTED_PROXY_HOPS` to the exact number of trusted proxies between the browser and Django and `AUDIT_TRUSTED_PROXY_NETWORKS` to the proxy container subnets. Django ignores forwarded identities from an untrusted peer or short/malformed chain. Forward these stdout events and the MariaDB audit file to the institution's protected logging system with its approved retention and review policy.

Data-preparing releases retain AES-256 encrypted, HMAC-authenticated pre-deployment database backups in daily, weekly, and monthly `predeploy-<period>-<timestamp>/` directories under `backups/`. Each directory contains `backup.sql.enc` and its `.hmac` sidecar and becomes visible only after both files are complete and verified. They use PBKDF2 with the MariaDB encryption password file and never write the SQL dump to disk in plaintext. At startup, deployment atomically encrypts, integrity-checks, and adopts any interrupted or legacy `.sql` or `.sql.tmp` snapshots before removing the plaintext copy. Ordinary application-only releases skip the expensive new dump along with derived refresh and parquet generation. These local snapshots do not replace encrypted off-VM backups and periodic restore testing.
The derived-table snapshot used for immediate data rollback is also encrypted and authenticated. It is removed when no retained deployment state references it.
