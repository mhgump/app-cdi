# CDI Framework

CDI is a self-contained deployment framework that runs containerized applications on GCP. It clones your git repository onto each cluster VM, builds a Docker image, and runs the container behind a global load balancer with autoscaling, Cloud SQL (Postgres 15), and Memorystore (Redis 7) as shared infrastructure.

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Prerequisites](#prerequisites)
3. [First-Time Setup](#first-time-setup)
4. [Deploying a Cluster](#deploying-a-cluster)
5. [App Contract](#app-contract)
6. [Environment Variables](#environment-variables)
7. [Managing Deployments](#managing-deployments)
8. [Teardown](#teardown)
9. [mTLS](#mtls)
10. [Local Development](#local-development)
11. [Reference Implementation](#reference-implementation)

---

## How It Works

On each cluster VM, a supervisor process:

1. Clones your git repository
2. Runs `docker build -t app:latest .`
3. Runs `docker run -d --name app -p <PORT>:<PORT> --env-file /etc/supervisor/app.env app:latest`
4. Monitors the container and restarts it if it exits
5. Polls for rebuild triggers every 10 seconds and redeploys when one is detected

Multiple VMs run your container simultaneously. All share the same Postgres instance (isolated by schema) and the same Redis instance (isolated by key prefix). The load balancer distributes traffic across all healthy instances with no sticky sessions.

---

## Prerequisites

```bash
brew install terraform
brew install --cask google-cloud-sdk
```

Authenticate with GCP:

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project <your-project-id>
```

---

## First-Time Setup

### 1. Configure `.envrc`

Run the interactive setup script to create your `.envrc`:

```bash
./scripts/init-envrc.sh
```

This sets the following variables, which all scripts and Terraform commands read automatically:

| Variable | Description |
|---|---|
| `PROJECT_ID` | GCP project ID (e.g. `my-company-dev-123`) |
| `TF_STATE_BUCKET` | GCS bucket name for Terraform remote state |
| `TF_VAR_project_id` | Same as `PROJECT_ID` — consumed by Terraform |
| `TF_VAR_namespace` | Prefix for all GCP resource names (e.g. `myco--myapp`) — prevents naming collisions |
| `DNS_ZONE` | Cloud DNS managed zone resource name (e.g. `myco-site`) |
| `DNS_DOMAIN` | Domain served by that zone (e.g. `myco.example.com`) |
| `REGION` | GCP region (default: `us-central1`) |

Load the environment manually, or install direnv for automatic loading:

```bash
# Manual — run once per shell session
source .envrc

# Automatic with direnv — add to ~/.zshrc once, then run once in this dir
eval "$(direnv hook zsh)"
direnv allow
```

### 2. Bootstrap (once per GCP project)

Enables required GCP APIs and creates the Terraform state bucket:

```bash
./scripts/bootstrap.sh
```

Enables: `compute`, `servicenetworking`, `sqladmin`, `redis`, `secretmanager`, `logging`, `monitoring`, `cloudresourcemanager`, `certificatemanager`, `networksecurity`

**Skip if already done.**

### 3. Deploy Shared Infrastructure (once per GCP project)

Creates the VPC, Cloud SQL instance, and Memorystore instance shared by all clusters. All resource names are prefixed with `TF_VAR_namespace`.

| Resource | GCP name example |
|---|---|
| VPC | `myco--myapp--network` |
| Cloud SQL (Postgres 15) | `myco--myapp--postgres` |
| Memorystore (Redis 7) | `myco--myapp--redis` |
| Postgres password secret | `myco--myapp--postgres-password` |

```bash
cd terraform/infra
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=infra"
terraform apply
cd ../..
```

> Cloud SQL takes 5–10 minutes. Memorystore takes 3–5 minutes.

Verify outputs:

```bash
cd terraform/infra && terraform output && cd ../..
```

Expected: `postgres_host`, `redis_host`, `network_self_link`, `subnet_self_link`, `network_name`.

**To undo shared infrastructure (affects all clusters):**

```bash
cd terraform/infra && terraform destroy && cd ../..
```

---

## Deploying a Cluster

```bash
./scripts/deploy.sh --key <key> --repo <owner>/<repo> [options]
```

The `--key` is the primary identifier for a deployment. It determines:

| Concept | Value |
|---|---|
| Domain | `<key>.<DNS_DOMAIN>` |
| Postgres schema (`POSTGRES_SCHEMA`) | `<key>` |
| Redis prefix (`REDIS_PREFIX`) | `<key>:` |

### Options

| Flag | Default | Description |
|---|---|---|
| `--key <key>` | *(required)* | Deployment key |
| `--repo <owner>/<repo>` | *(required)* | GitHub repository |
| `--data-namespace <ns>` | same as `--key` | Override Postgres schema and Redis prefix (see [Data Namespaces](#data-namespaces)) |
| `--machine-type <type>` | `e2-standard-2` | GCE machine type |
| `--min <n>` | `1` | Minimum instances |
| `--max <n>` | `10` | Maximum instances |
| `--cpu-target <0.0-1>` | `0.6` | Autoscale CPU target |
| `--port <n>` | `8080` | Container port |
| `--health-path <path>` | `/health` | Health check path |
| `--build-context <path>` | repo root | Subdirectory for Docker build context |
| `--dockerfile <path>` | `Dockerfile` in build context | Path to Dockerfile relative to repo root |
| `--region <name>` | `us-central1` | GCP region |
| `--zones <z1,z2>` | all in region | Comma-separated zones |
| `--disk-size <gb>` | `50` | Boot disk size in GB |
| `--github-token <token>` | — | GitHub PAT for deploy key registration (private repos only; see below) |
| `--mtls <path>` | — | Path to CA cert from `gen-ca.sh`; enforces mTLS on the HTTPS load balancer |

### Example

```bash
./scripts/deploy.sh \
  --key kvstore \
  --repo mhgump/cdi-kvstore \
  --machine-type e2-micro \
  --min 1 \
  --max 5 \
  --disk-size 30
```

Output:

```
Cluster 'kvstore' deployed.
  Load balancer IP: 34.X.X.X
  URL: https://kvstore.<DNS_DOMAIN>  (SSL cert takes ~15 min after DNS propagates)
```

The HTTP endpoint is available within ~3 minutes. HTTPS becomes available after DNS propagates and the managed cert provisions (~15 min).

### Public vs Private Repositories

The script automatically detects whether your repo is public or private:

- **Public repo** — no token needed. The script clones via HTTPS with no credentials.
- **Private repo with `--github-token`** — the script registers your local SSH public key as a read-only deploy key on GitHub automatically.
- **Private repo without `--github-token`** — the script pauses, prints the public key, and waits for you to add it to the repo as a deploy key manually before continuing.

### Data Namespaces

By default the `--key` controls both the domain and the data namespace (Postgres schema + Redis prefix). Use `--data-namespace` to decouple them — useful for running an admin service that reads the same data as a user-facing service:

```bash
# Primary deployment — domain: prod.<DNS_DOMAIN>, schema: prod, prefix: prod:
./scripts/deploy.sh --key prod --repo org/myapp

# Admin deployment — domain: prod-admin.<DNS_DOMAIN>, same schema and prefix as prod
./scripts/deploy.sh --key prod-admin --repo org/myapp-admin --data-namespace prod
```

Both receive `POSTGRES_SCHEMA=prod` and `REDIS_PREFIX=prod:`, share the same data, but are independently scalable.

> **Warning:** When using `--data-namespace`, tearing down either deployment will flush the shared Redis keys and drop the shared Postgres schema. Tear down the primary deployment last, or clean up manually.

---

## App Contract

Your repository must satisfy this contract to work with CDI.

### Checklist

- [ ] Repository root contains a `Dockerfile`
- [ ] App listens on `$PORT` (never a hardcoded port)
- [ ] `GET /health` returns HTTP 200
- [ ] App handles `SIGTERM` for graceful shutdown
- [ ] All env vars read as named constants at startup (not scattered inline `process.env` calls)
- [ ] Postgres schema created with `CREATE SCHEMA IF NOT EXISTS "$POSTGRES_SCHEMA"` at startup
- [ ] All Postgres tables created inside `$POSTGRES_SCHEMA`
- [ ] All Redis keys prefixed with `$REDIS_PREFIX`
- [ ] Schema and table creation is idempotent (`CREATE TABLE IF NOT EXISTS`)

### Dockerfile

The framework runs `docker build -t app:latest .` with no build arguments and no compose files. Your `Dockerfile` must be at the repository root (or at `--build-context`/`--dockerfile` if specified).

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --production
COPY . .
EXPOSE 8080
CMD ["node", "server.js"]
```

### Health Check

The load balancer calls `GET /health` every few seconds. Return HTTP 200 or the instance is removed from the pool.

Include instance metadata in the response — it helps debugging:

```json
{ "ok": true, "instance": "kvstore-a1b2-xyz", "cluster": "kvstore" }
```

**Startup grace period:** The load balancer waits 180 seconds after instance boot before health checks begin. Respond to `/health` as soon as possible — the grace period exists for slow boots, not as an invitation to delay startup.

The load balancer has a **24-hour backend timeout** to support long-lived WebSocket connections.

### WebSocket Connections

CDI always serves traffic over HTTPS. Browsers block `ws://` connections on HTTPS pages as mixed content — the connection fails silently with no visible error.

Always derive the WebSocket protocol from the page protocol:

```javascript
const proto = location.protocol === 'https:' ? 'wss' : 'ws';
const ws = new WebSocket(`${proto}://${location.host}/your-path`);
```

Never hardcode `ws://` in a frontend that will be deployed through CDI.

### SIGTERM Handling

The container receives `SIGTERM` before it is stopped. Flush connections, finish in-flight requests, then exit cleanly.

### Multi-Instance Behavior

Multiple VMs run your container simultaneously. Design accordingly:

- **Idempotent startup.** All instances run the same startup code concurrently. Use `CREATE SCHEMA IF NOT EXISTS` and `CREATE TABLE IF NOT EXISTS` — never bare `CREATE`.
- **No one-time jobs at startup.** Migrations, seed scripts, or any "run once" logic will execute on every instance. Run these as a separate step before deploying, or use a distributed lock via Redis.
- **No sticky sessions.** Any request can land on any instance.
- **Use Redis for cross-instance state.** Shared caches, pub/sub for WebSocket broadcast, distributed locks.

---

## Environment Variables

The supervisor writes all variables to `/etc/supervisor/app.env` and passes them to the container via `--env-file`.

Define all injected variables as named constants at the top of your entry point:

### Node.js

```javascript
// ── Infrastructure constants (injected by CDI framework) ────────────────────
const PORT          = Number(process.env.PORT)          || 8080;
const CLUSTER_NAME  = process.env.CLUSTER_NAME          || 'local';
const INSTANCE_ID   = process.env.INSTANCE_ID           || require('os').hostname();

const POSTGRES_HOST     = process.env.POSTGRES_HOST     || null;
const POSTGRES_USER     = process.env.POSTGRES_USER     || 'postgres';
const POSTGRES_PASSWORD = process.env.POSTGRES_PASSWORD || '';
const POSTGRES_SCHEMA   = process.env.POSTGRES_SCHEMA   || 'public';

const REDIS_HOST   = process.env.REDIS_HOST   || '127.0.0.1';
const REDIS_PORT   = Number(process.env.REDIS_PORT) || 6379;
const REDIS_PREFIX = process.env.REDIS_PREFIX || '';
```

### Python

```python
import os

# ── Infrastructure constants (injected by CDI framework) ────────────────────
PORT          = int(os.environ.get("PORT", 8080))
CLUSTER_NAME  = os.environ.get("CLUSTER_NAME", "local")
INSTANCE_ID   = os.environ.get("INSTANCE_ID") or os.uname().nodename

POSTGRES_HOST     = os.environ.get("POSTGRES_HOST")
POSTGRES_USER     = os.environ.get("POSTGRES_USER", "postgres")
POSTGRES_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "")
POSTGRES_SCHEMA   = os.environ.get("POSTGRES_SCHEMA", "public")

REDIS_HOST   = os.environ.get("REDIS_HOST", "127.0.0.1")
REDIS_PORT   = int(os.environ.get("REDIS_PORT", 6379))
REDIS_PREFIX = os.environ.get("REDIS_PREFIX", "")
```

### Variable Reference

**Always present:**

| Variable | Description | Example |
|---|---|---|
| `PORT` | Port the container must listen on | `8080` |
| `CLUSTER_NAME` | Name of this CDI cluster | `kvstore` |
| `INSTANCE_ID` | GCP VM name running this container | `kvstore-a1b2-xyz` |

**Postgres (Cloud SQL — PostgreSQL 15):**

| Variable | Description | Example |
|---|---|---|
| `POSTGRES_HOST` | Private IP of the Cloud SQL instance | `10.0.0.5` |
| `POSTGRES_USER` | Database user | `app` |
| `POSTGRES_PASSWORD` | Database password (from Secret Manager) | `s3cr3t` |
| `POSTGRES_SCHEMA` | Schema for this deployment — equals `--key`, or `--data-namespace` if set | `kvstore` |

**Redis (Memorystore — Redis 7):**

| Variable | Description | Example |
|---|---|---|
| `REDIS_HOST` | Private IP of the Memorystore instance | `10.0.0.10` |
| `REDIS_PORT` | Redis port | `6379` |
| `REDIS_PREFIX` | Key namespace prefix — `<key>:`, or `<data-namespace>:` if set | `kvstore:` |

### Postgres Usage

The framework does **not** create your schema. Create it at startup before touching any tables:

```javascript
const { Pool } = require('pg');

const pool = new Pool({
  host:     POSTGRES_HOST,
  user:     POSTGRES_USER,
  password: POSTGRES_PASSWORD,
  database: 'postgres',           // always connect to the default database
  ssl:      { rejectUnauthorized: false },  // Cloud SQL uses a private CA
});

async function initDb() {
  await pool.query(`CREATE SCHEMA IF NOT EXISTS "${POSTGRES_SCHEMA}"`);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS "${POSTGRES_SCHEMA}".items (
      id    SERIAL PRIMARY KEY,
      key   TEXT NOT NULL UNIQUE,
      value TEXT
    )
  `);
}
```

- Connect to database `postgres` — there is no `POSTGRES_DB` variable.
- Always use `ssl: { rejectUnauthorized: false }` (Node) or `sslmode=require` (Python/psycopg2).
- Never write to `public` or another deployment's schema.
- If your key contains hyphens (e.g. `my-app`), double-quote the schema name in all SQL: `"my-app".tablename`.
- The schema is **dropped with CASCADE** on teardown — unless multiple deployments share the same `--data-namespace`, in which case only the last teardown drops it.

### Redis Usage

Prefix **all** keys with `$REDIS_PREFIX` to avoid collisions:

```javascript
const key = `${REDIS_PREFIX}user:${userId}`;
```

- `REDIS_PREFIX` is `<key>:` by default, or `<data-namespace>:` if set. All keys matching the prefix are flushed on teardown.
- Connect without TLS — Memorystore does not use SSL by default.
- Use Redis pub/sub with the prefix for cross-instance messaging (e.g. WebSocket broadcast).

---

## Managing Deployments

### List all clusters

```bash
./scripts/list.sh
```

Output: cluster name, region, instance count, status, and load balancer IP.

### Rebuild after code changes

Push your changes to git, then trigger a rolling rebuild across all running instances:

```bash
./scripts/rebuild.sh --key <key>
```

Each instance pulls the latest code, rebuilds the image, and restarts the container within ~30 seconds. The supervisor detects the trigger within ~10 seconds.

To deploy a specific commit, branch, or tag:

```bash
./scripts/rebuild.sh --key <key> <commit-or-ref>
```

### View logs

Find running instances:

```bash
gcloud compute instance-groups managed list-instances cluster-<key> \
  --region=us-central1 \
  --project=$PROJECT_ID
```

Tail the supervisor log on an instance (includes container lifecycle, build output, and app stdout/stderr):

```bash
gcloud compute ssh <instance-name> \
  --zone=<zone> \
  --project=$PROJECT_ID \
  -- journalctl -fu supervisor
```

Your application's stdout/stderr appears inside the supervisor log as Docker container output.

Expected log lines after a successful boot:

```
[supervisor] Repo HEAD: abc1234
[supervisor] Image built.
[supervisor] Container up: Up 2 minutes
[server] :8080  instance=kvstore-xxxx  cluster=kvstore
```

---

## Teardown

Destroy a single cluster (MIG, load balancer, firewall, service account, Postgres schema, Redis keys, Secret Manager secrets):

```bash
./scripts/takedown.sh --key <key>
```

The script prompts you to type the key to confirm before destroying anything.

For private repos, pass `--github-token` to automatically revoke the deploy key from GitHub:

```bash
./scripts/takedown.sh --key <key> --github-token <token>
```

To also destroy shared infrastructure (Postgres + Redis + VPC — **affects all clusters**):

```bash
cd terraform/infra && terraform destroy && cd ../..
```

---

## mTLS

To restrict access to your cluster's HTTPS endpoint to clients presenting a trusted certificate:

### 1. Generate a CA

```bash
./scripts/gen-ca.sh [--out <dir>] [--days <n>] [--cn <name>]
```

| Flag | Default | Description |
|---|---|---|
| `--out <dir>` | `./mtls` | Output directory |
| `--days <n>` | `3650` | Certificate validity in days |
| `--cn <name>` | `CDI mTLS CA` | Common Name for the CA |

Outputs `ca.key` (keep secret, never commit) and `ca.crt`.

### 2. Deploy with mTLS

Pass the CA cert to `deploy.sh`. The load balancer will reject any client that does not present a certificate signed by this CA:

```bash
./scripts/deploy.sh --key <key> --repo <owner>/<repo> --mtls ./mtls/ca.crt
```

### 3. Issue client certificates

```bash
./scripts/issue-cert.sh \
  --ca-cert ./mtls/ca.crt \
  --ca-key  ./mtls/ca.key \
  --cn      <client-name> \
  [--days   <n>] \
  [--out    <path-prefix>]
```

| Flag | Default | Description |
|---|---|---|
| `--ca-cert <path>` | *(required)* | Path to CA certificate |
| `--ca-key <path>` | *(required)* | Path to CA private key |
| `--cn <name>` | *(required)* | Common Name for the client cert |
| `--days <n>` | `30` | Validity in days |
| `--out <prefix>` | `./<cn>` | Output path prefix — writes `<prefix>.crt` and `<prefix>.key` |

Distribute the `.crt` and `.key` to the client. Connect with:

```bash
curl --cert client.crt --key client.key https://<key>.<DNS_DOMAIN>/...
```

---

## Local Development

Design your app to run without GCP infrastructure. Detect missing services at startup and degrade gracefully:

- If `POSTGRES_HOST` is unset → fall back to in-memory storage or a local Postgres container
- If Redis is unavailable → skip pub/sub, serve local clients only

Quick local run:

```bash
docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=dev postgres:15
docker run -d -p 6379:6379 redis:7

POSTGRES_HOST=127.0.0.1 POSTGRES_USER=postgres POSTGRES_PASSWORD=dev \
POSTGRES_SCHEMA=public REDIS_HOST=127.0.0.1 REDIS_PREFIX=local: \
PORT=3000 node server.js
```

---

## Reference Implementation

`cdi-kvstore/` is the canonical reference app. It demonstrates:

- Constants pattern for all injected environment variables
- Idempotent schema and table creation at startup
- Postgres schema creation and table management
- Redis key namespacing with `REDIS_PREFIX`
- Redis pub/sub for cross-instance WebSocket broadcast
- Graceful degradation when services are unavailable
- Health endpoint returning instance metadata

See `cdi-kvstore/README-LIVE-TEST.md` for the full deployment and validation guide.
