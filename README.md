# Intelvia Deployment

This is a generated, deploy-only repository for published, immutable Intelvia images. Do not maintain or directly edit generated files here: changes may be overwritten by the next synchronization from `Intelvia/intelvia`, which is the sole source of truth.

Only the checked-in Compose files, nginx templates, deploy/rollback scripts, environment examples, MariaDB configuration, and this documentation are generated. VM-local `.env` files, Docker credentials, `.deploy-state/`, `backups/`, and all parquet data are deliberately untracked and are never synchronized back to GitHub.

## Hospital releases

Hospital deployments use `docker-compose.yml`. `.env.example` is updated only when an operator-approved semantic release such as `v1.2.3` or `v1.2.3-beta.1` is published.

```bash
cp .env.example .env
# Configure the institution hostname, CAS, MariaDB, Sentry, and integration values.
docker login docker.io
docker compose pull
docker compose up -d
```

Backend restarts apply Django migrations but do not recreate populated derived tables. On a first installation, run the data preparation and validation commands below before using the application.

`INTELVIA_IMAGE_TAG` must remain an explicit semantic version. Intelvia does not publish or support `latest`, `edge`, or other mutable deployment tags.

MariaDB uses the `intelvia_mariadb_data` volume because the Compose project name is fixed to `intelvia`. The parquet cache remains a separate `./backend/parquet_cache` bind mount.

After a source-data refresh, explicitly rebuild derived data and parquets:

```bash
docker compose run --rm backend poetry run python manage.py prepare_parquet_set --commit
docker compose run --rm backend poetry run python manage.py validate_parquets \
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
- Pull-only Docker Hub credentials stored in the GitHub production environment.
- Existing parquets copied into `parquets/sets/bootstrap` under the deployment checkout, or permission for the first deployment to run forced data preparation.

The deploy workflow requires these GitHub environment secrets:

- `PRODUCTION_DEPLOY_HOST`, `PRODUCTION_DEPLOY_PORT`, `PRODUCTION_DEPLOY_USER`
- `PRODUCTION_DEPLOY_SSH_KEY`, `PRODUCTION_DEPLOY_KNOWN_HOSTS`
- `PRODUCTION_APP_DIR`
- `PRODUCTION_DOCKERHUB_USERNAME`, `PRODUCTION_DOCKERHUB_TOKEN`

Pin `PRODUCTION_DEPLOY_KNOWN_HOSTS` out of band and keep `StrictHostKeyChecking=yes`. The VM credential needs pull access only; GitHub's existing Docker Hub credentials retain publish access.

## Blue-green and parquet behavior

The deployment script keeps one MariaDB service and switches between blue/green frontend/backend pairs on ports 8080 and 8081. Each backend mounts its parquet set read-write at `/app/parquet_cache`; generated scoped artifacts live under `/app/parquet_cache/user_artifacts`. Nginx reads `/etc/nginx/snippets/intelvia-active-upstream.conf` and is changed only after the inactive pair serves the requested frontend bundle and passes frontend and database/parquet-aware backend health checks.

Data-impacting commits are detected with `detect-data-impact.sh` and `data-impact-paths.txt`. The supported modes are:

- `auto`: rebuild only for detected data-contract changes; required for automatic main deployments.
- `force`: always refresh derived tables and stage a new parquet set.
- `reuse`: explicitly reuse the current set; manual operator override only.

New files are generated under `parquets/.staging/<image-tag>-<timestamp>` in the deployment checkout, validated, and promoted to the matching path under `parquets/sets/` only during a healthy cutover. The timestamp preserves rollback identity when an operator force-regenerates data for the same image. Each validated set includes `validation_manifest.json` with its producer, checksums, sizes, row counts, and Arrow schemas; a later regeneration removes this report until validation runs again. `manifest.json` tracks active artifact versions. The deploy refuses data preparation unless it can retain the active set plus `MIN_PARQUET_FREE_BYTES` of headroom.

The scheduled `Refresh intelvia.app production data` workflow runs daily at 02:00 UTC. It reuses the active image digests and exact deploy-package commit, then performs the same staged blue-green cutover in `force` mode. This replaces direct Celery writes into the active immutable parquet set.

Backend and frontend tags are resolved to registry digests before Compose starts a candidate. Deployment state records those digests and the exact generated deploy-repository commit so rollback never depends on a tag or an unpinned `git pull`.

Deployment state and rollback records live under `.deploy-state/`. List recorded IDs with:

```bash
ls -1 .deploy-state/history
```

Restore a recorded application/parquet pair with:

```bash
bash rollback.sh <deployment-id>
```

Rollback does not reverse Django migrations. Deployment state increments a schema generation whenever migration files change and refuses rollback to a state from another generation. A new forward deployment is required across that boundary. Application-only rollback can use any retained state in the current schema generation. A rollback that changes parquet data is limited to the immediately previous parquet generation because that is the generation whose matching SQL-derived tables are snapshotted and verified during restore.

The newest `ROLLBACK_RETENTION_COUNT` successful states are retained, defaulting to five; older state files and their unreferenced parquet sets are removed together. Unused images older than seven days are pruned after a successful deployment. A rollback whose local image was pruned pulls its recorded digest again from Docker Hub.

Before mutation, `deploy.sh` writes `.deploy-state/pending.env`. Signals run the same idempotent cleanup used for command failures. If the process or host disappears, the next deployment treats `current.env` as authoritative, restores nginx and the parquet pointer, restores backed-up derived tables, removes the candidate, and then continues. Do not edit `current.env` or `pending.env` manually.

The public health endpoint validates MariaDB, global parquet schemas, and a write/delete probe in `/app/parquet_cache/user_artifacts`. Deployment also checks the authentication mode configured in the VM-local `.env`: `DJANGO_DISABLE_LOGINS=True` must return the login-disabled access payload, while `False` must reach CAS through the redirect chain. Representative department/provider access should still be exercised through the institution's non-PHI smoke accounts when CAS is enabled.

Data-preparing releases retain pre-deployment database backups as daily, weekly, and monthly snapshots under `backups/`. They also retain the smaller derived-table snapshot needed for an immediate data rollback; it is removed when no retained deployment state references it. Ordinary application-only releases skip the expensive full dump along with derived refresh and parquet generation. These local snapshots do not replace encrypted off-VM backups and periodic restore testing.
