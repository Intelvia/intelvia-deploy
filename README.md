# Intelvia Deployment

This repository contains the deployment artifacts for running Intelvia from published container images. It is generated from the private Intelvia source repository; direct edits here may be overwritten by the next sync.

## Contents

- `docker-compose.yml`: production container stack
- `.env.example`: required environment variables
- `server-nginx.conf`: example VM-level TLS reverse proxy
- `mariadb/conf.d/`: MariaDB runtime configuration

Application source code is intentionally not included.

## Registry Access

If the Intelvia images are private, authenticate to the registry before starting the stack:

```bash
docker login docker.io
```

The deploying institution needs pull access to these images:

- `docker.io/intelvia/intelvia-backend`
- `docker.io/intelvia/intelvia-frontend`

## Configure

Create a local `.env` file from the example:

```bash
cp .env.example .env
```

Set production values for Django, MariaDB, CAS, monitoring, and any institution-specific integration settings. Do not commit `.env`.

Update `server-nginx.conf` with the deployment hostname and TLS certificate paths, or adapt it to the institution's existing nginx configuration.

## Start

```bash
docker compose up -d
```

The backend container applies Django migrations and installs SQL-managed derived tables on startup.

After initial data load or any source-data refresh, rebuild the derived tables and parquet cache:

```bash
docker compose run --rm backend poetry run python manage.py refresh_derived_tables
docker compose run --rm backend poetry run python manage.py generate_parquets
docker compose restart backend frontend
```

## Upgrade

Pull the latest deployment repository changes, then pull and restart containers:

```bash
git pull
docker compose pull
docker compose up -d
```

Run the derived-data refresh commands above when the release notes or deployment operator indicate that source data or derived artifacts need to be rebuilt.
