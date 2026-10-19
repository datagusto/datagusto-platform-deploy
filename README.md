# DataGusto Platform - deployment files

Docker Compose files to run the DataGusto Platform from the container images
that datagusto publishes to a private Amazon ECR registry. Use this
repository when you have been given pull access; nothing here needs the
source code. The registry host, the access role and the image versions are
sent to you separately.

The tags of this repository match the image versions: check out `v0.1.0`
to deploy images tagged `0.1.0`.

| File | Purpose |
|---|---|
| `docker-compose.yml` | The deployment: proxy, frontend, backend, migrations, PostgreSQL |
| `docker-compose.tls.yml` | Optional override: HTTPS with your own certificate |
| `docker-compose.external-db.yml` | Optional override: use an existing PostgreSQL server |
| `nginx/` | Proxy configuration used by the files above |
| `.env.example` | All settings, required ones first |
| `scripts/ecr-login.sh` | Logs Docker in to the registry |

## Requirements

- Linux server on x86_64 (amd64) with Docker Engine 24+ and Docker Compose
  v2.24+ (`docker compose version`). The images are built for `linux/amd64`
  only; on an ARM host (for example AWS Graviton or Apple silicon)
  `docker compose pull` fails with "no matching manifest for linux/arm64".
- AWS CLI v2 on the server (or on the machine that pulls the images).
- 2 CPU / 4 GB RAM minimum, 20 GB disk for images and data.
- One hostname (or IP) that users will open in the browser, with port 80
  open on the server (443 as well when using HTTPS).
- Outbound HTTPS from the pulling machine to Amazon ECR (`*.amazonaws.com`).

## 1. Registry access

datagusto gives each partner an IAM role in its AWS account that can only
pull the images. You receive the role ARN and the registry host privately;
allow your own IAM users or roles to call `sts:AssumeRole` on the role, then
add a profile:

```ini
# ~/.aws/config
[profile datagusto]
role_arn = <role ARN you were given>
source_profile = <your own profile>
region = <region of the registry you were given>
```

Log Docker in (valid for 12 hours; reads the registry from `IMAGE_REGISTRY`
in `.env`, or pass `ECR_REGISTRY=<registry host>`):

```bash
scripts/ecr-login.sh datagusto
```

## 2. Install

```bash
git clone https://github.com/datagusto/datagusto-platform-deploy.git
cd datagusto-platform-deploy
git checkout v0.1.0            # the image version you were told to run

cp .env.example .env
# Fill in: PUBLIC_BASE_URL, POSTGRES_PASSWORD, JWT_SECRET_KEY, JWT_REFRESH_SECRET_KEY
# Generate keys with: openssl rand -hex 32
# Set IMAGE_REGISTRY to the registry host you were given, with a trailing slash.

docker compose pull
docker compose up -d
docker compose ps              # all services "running" / "healthy"
curl -fsS http://<host>/health
```

Open `http://<host>/` in a browser.

### First account

Sign-up is disabled by default. To create the first account:

```bash
# .env: ENABLE_REGISTRATION=true
docker compose up -d backend
# open http://<host>/sign-up and create the account
# .env: ENABLE_REGISTRATION=false
docker compose up -d backend
```

Further users are added by an organization owner or admin from the
organization settings page.

### License key

Open the organization's "License & usage" page and paste the license key
you received from datagusto. Activation works offline.

## 3. Connecting agents and plugins

Agents, SDKs and plugins talk to the backend through the same proxy as the
browser. Backend port 8000 is not published, so the base URL to configure in
a plugin is the deployment's public URL, with no port and no path:

| Setting in the plugin / SDK | Value | Example |
|---|---|---|
| Base URL (`DATAGUSTO_URL` in the SDK examples) | the `PUBLIC_BASE_URL` from `.env` | `http://datagusto.example.local`, or `https://datagusto.example.com` with TLS |
| API key | issued per agent in the UI: project → agent → "API keys" → "Create API key" | `agt_live_...` (shown once) |

The key is sent as `Authorization: Bearer agt_live_...`. Do not append
`/api/v1`; the client adds the paths. Do not use `localhost` from another
machine or container: use the address under which the proxy is reachable.

Check the connection from the machine that runs the agent:

```bash
BASE=http://datagusto.example.local      # = PUBLIC_BASE_URL
KEY=agt_live_...

curl -fsS "$BASE/health"                                   # {"status":"ok"}
curl -fsS -H "Authorization: Bearer $KEY" "$BASE/api/v1/public/safety/whoami"
# -> {"agent_id": "...", "name": "<agent name>", "project_id": "...", "organization_id": "..."}
```

Endpoints the integrations use, all under `$BASE`:

| Path | Purpose |
|---|---|
| `POST /api/v1/public/safety/tools/register` | register the agent's tool definitions |
| `POST /api/v1/public/safety/sessions/alignment` | start a session from the user's instruction |
| `POST /api/v1/public/safety/sessions/validate` | validate a tool call before (`on_start`) and after (`on_end`) it runs |
| `POST /api/v1/public/guardrails/evaluate` | stateless guardrail evaluation |
| `GET /api/v1/public/safety/whoami` | identity of the key's agent (setup preflight) |
| `/api/v1/traces/...` | trace and observation upload |

The API reference and integration guides in the product documentation
describe the request and response formats.

## 4. Replacing an existing deployment

If you already run the platform from an earlier compose file (for example
one that builds from source or loads images from a tar archive), switch to
these files instead of editing yours:

1. Back up the database:
   `docker compose exec postgres pg_dump -U datagusto datagusto | gzip > backup-$(date +%F).sql.gz`
2. Copy `docker-compose.yml`, the overrides you use, and `nginx/` from this
   repository over your deployment directory, replacing your files of the
   same names. Keep your existing `.env`. Plugins keep working as long as
   `PUBLIC_BASE_URL` stays the same (see section 3). Use the `docker compose` (v2)
   command; `docker-compose.external-db.yml` needs Compose v2.24 or later.
3. Add to `.env`:
   ```dotenv
   IMAGE_REGISTRY=<registry host you were given>/
   DATAGUSTO_VERSION=0.1.0
   ```
   and compare the rest against `.env.example`; variable names are the same
   as in the tar-archive bundle.
4. `scripts/ecr-login.sh datagusto && docker compose pull && docker compose up -d`.

The database volume (`postgres_data`) is reused as long as you start from
the same directory (Compose derives the project name from it), or set
`COMPOSE_PROJECT_NAME` in `.env` to your previous project name.

## 5. Upgrade

```bash
docker compose exec postgres pg_dump -U datagusto datagusto | gzip > backup-$(date +%F).sql.gz
git fetch --tags && git checkout v<new>     # keeps your .env
# .env: DATAGUSTO_VERSION=<new>
scripts/ecr-login.sh datagusto
docker compose pull
docker compose up -d        # runs database migrations, then restarts services
```

Roll back by restoring the previous `DATAGUSTO_VERSION` and, if the
migration changed the schema, the database dump.

## Options

### HTTPS with your own certificate

```bash
mkdir certs && cp your.crt certs/server.crt && cp your.key certs/server.key
# .env: PUBLIC_BASE_URL=https://<host>
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
```

Port 80 redirects to HTTPS. Without this override the platform runs on
plain HTTP and session cookies are not marked `Secure`; use HTTPS whenever
the network is shared with other systems.

### Existing PostgreSQL server

Create a database and a user that may create tables and the `pg_trgm`
extension, set `POSTGRES_HOST/PORT/DB/USER/PASSWORD` in `.env`, then:

```bash
docker compose -f docker-compose.yml -f docker-compose.external-db.yml up -d
```

### Mirroring the images into your own registry

```bash
SRC=<registry host you were given>
for i in datagusto-backend datagusto-frontend; do
  docker pull $SRC/$i:<version>
  docker tag  $SRC/$i:<version> registry.example.local/datagusto/$i:<version>
  docker push registry.example.local/datagusto/$i:<version>
done
# .env: IMAGE_REGISTRY=registry.example.local/datagusto/
```

### Outbound proxy and private CA

Only optional integrations (LLM provider, Slack, e-mail, Azure DevOps,
GitHub) make outbound connections. If they must go through a proxy or trust
an internal CA, set `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` and put the
CA bundle at `./ca/ca.pem` with `SSL_CERT_FILE=/etc/datagusto/ca/ca.pem`.
That file replaces the system trust store, so it must contain the public
CAs as well as your own.

## Operate

```bash
docker compose logs --since 1h backend proxy
```

Logs rotate automatically (50 MB x 5 files per service). The bundled
database lives in the `postgres_data` volume; dump it with `pg_dump` as
shown above on a schedule, and keep a copy of `.env`. When contacting
support, include the output of `docker compose ps`, the image version, and
the relevant logs.

## Network and request routing

Only the proxy publishes a port. Every other service is reachable solely on
the internal Compose network `datagusto`.

```
browser ──HTTP :80 (or :443 with TLS)──▶ proxy (nginx)
                                          ├─ /            ──▶ frontend:3000  (Next.js)
                                          ├─ /api/        ──▶ backend:8000   (FastAPI)
                                          └─ /health      ──▶ backend:8000
                                       backend ──▶ postgres:5432 (internal only)
agent / SDK ──HTTP :80 /api/v1/public/…──▶ proxy ──▶ backend:8000
```

| Service | Image | Listens on | Published to host | Called by |
|---|---|---|---|---|
| `proxy` | `nginx:1.27-alpine` | 80 (443 with `docker-compose.tls.yml`) | `HTTP_PORT` (default 80), `HTTPS_PORT` (default 443) | browsers, agents |
| `frontend` | `datagusto-frontend` | 3000 | no | proxy |
| `backend` | `datagusto-backend` | 8000 | no | proxy, `backend-migrations` shares its image |
| `backend-migrations` | `datagusto-backend` | - | no | runs `alembic upgrade head` once at start, then exits |
| `postgres` | `postgres:15-alpine` | 5432 | no | backend (omitted with `docker-compose.external-db.yml`) |

Routing rules live in `nginx/default.conf` (HTTP) and `nginx/tls.conf`
(HTTPS, with an HTTP → HTTPS redirect that keeps `/health` on port 80 for
load-balancer checks). The browser and the public API use the same origin,
so `PUBLIC_BASE_URL` is the only URL to configure; the backend derives its
allowed CORS origin and the links in notifications from it. Requests to
`/api/` are proxied with long timeouts (LLM-backed calls can run for
minutes) and a 50 MB body limit for trace uploads.

Start order: `postgres` (healthy) → `backend-migrations` (completes) →
`backend` (healthy) → `proxy`. `frontend` starts independently. Health
endpoints: `GET /health` on the proxy (answered by the backend) and the
containers' own health checks shown by `docker compose ps`.

## Network footprint

| Direction | Target | Required |
|---|---|---|
| Inbound | port 80 (443 with TLS) on the proxy | yes |
| Outbound | the ECR registry host (`*.amazonaws.com`) | only while pulling images |
| Outbound | LLM provider endpoint | only for LLM features |
| Outbound | Slack, SMTP server | only for notifications |
| Outbound | Azure DevOps, GitHub | only for ticket integrations |

No other outbound connections are made.

## License

The files in this repository are MIT licensed (see `LICENSE`). The container
images are proprietary and available only under a separate agreement with
datagusto.
