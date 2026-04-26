# GBrain — Dokploy Deployment

Two Dokploy Compose services on the same Hetzner server, connected via `dokploy-network`.

```
[Dokploy project: supabase]      [Dokploy project: gbrain]
  db (postgres+pgvector)  ←────── gbrain    :8787  (Traefik)
  studio, kong, auth...            gbrain-worker    (internal)

Shared network: dokploy-network (already exists in Dokploy)
Scheduler:      Dokploy Schedule Jobs
```

---

## Part 1 — Deploy Supabase self-hosted in Dokploy

### Step 1.1 — Fork and prepare the Supabase repo

Fork `https://github.com/supabase/supabase` to your GitHub account.

In your fork, open `docker/docker-compose.yml` and make **two changes** to the `db` service:

**Add a fixed container name** (so GBrain can reach it by a known name):
```yaml
db:
  container_name: supabase-db
  ...
```

**Add `dokploy-network`** to the db service networks and declare it at the bottom:
```yaml
db:
  container_name: supabase-db
  networks:
    - default
    - dokploy-network
  ...

networks:
  default:
    driver: bridge
  dokploy-network:
    external: true
```

Commit and push to your fork.

### Step 1.2 — Create Supabase Compose service in Dokploy

Dokploy UI → **New Project** (name it `supabase`) → **New Service** → **Compose**:
- Compose Type: `Docker Compose`
- Provider: GitHub → your forked repo → branch: `master`
- Compose Path: `./docker/docker-compose.yml`
- Click **Save**

### Step 1.3 — Set Supabase environment variables

Dokploy UI → supabase Compose service → **Environment** tab.

Generate secrets first — use the Supabase key generator at:
`https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys`

| Name | Value |
|---|---|
| `POSTGRES_PASSWORD` | *(strong generated password)* |
| `JWT_SECRET` | *(32+ char random string)* |
| `ANON_KEY` | *(generated from JWT_SECRET)* |
| `SERVICE_ROLE_KEY` | *(generated from JWT_SECRET)* |
| `DASHBOARD_USERNAME` | `supabase` |
| `DASHBOARD_PASSWORD` | *(strong password)* |
| `API_EXTERNAL_URL` | `https://brain-db.shapememory.eu` |
| `SITE_URL` | `https://brain-db.shapememory.eu` |
| `POSTGRES_HOST` | `db` |
| `POSTGRES_DB` | `postgres` |
| `POSTGRES_PORT` | `5432` |

### Step 1.4 — Configure Supabase domain (optional)

Dokploy UI → supabase Compose → **Domains** tab → Add Domain:
- Host: `brain-db.shapememory.eu`
- Service: `kong`
- Port: `8000`
- HTTPS: enabled

### Step 1.5 — Deploy Supabase

Click **Deploy**. Wait for all containers to become healthy (~3-5 min).
Verify at `https://supabase.yourdomain.eu` — Studio should load.

---

## Part 2 — Deploy GBrain in Dokploy

### Step 2.1 — Prepare host directories

Dokploy UI → supabase Compose → **Terminal** tab (on the `db` service), run:

```
psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS vector;"
psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
```

Then on the **Hetzner server** (SSH or Dokploy server terminal):
```
mkdir -p /var/www/hilvara/gbrain/brain
mkdir -p /var/www/hilvara/gbrain/config
```

### Step 2.2 — Create GBrain Compose service in Dokploy

Dokploy UI → **New Project** (name it `gbrain`) → **New Service** → **Compose**:
- Compose Type: `Docker Compose`
- Provider: GitHub → this repo → branch: `main`
- Compose Path: `./docker-compose.yml`
- Click **Save**

### Step 2.3 — Set GBrain environment variables

Dokploy UI → gbrain Compose service → **Environment** tab:

| Name | Value | Notes |
|---|---|---|
| `DATABASE_URL` | `postgresql://postgres:PASSWORD@supabase-db:5432/postgres` | Use your Supabase POSTGRES_PASSWORD |
| `OPENAI_API_KEY` | `sk-...` | Required — vector embeddings |
| `ANTHROPIC_API_KEY` | `sk-ant-...` | Recommended — query expansion |
| `GROQ_API_KEY` | *(blank if unused)* | Optional — voice transcription |
| `GBRAIN_DOMAIN` | `brain.yourdomain.eu` | Your public domain |
| `MINIONS_CONCURRENCY` | `4` | Parallel background jobs |

> `supabase-db` is the fixed container name set in Step 1.1.
> Both services are on `dokploy-network` so this resolves directly.

### Step 2.4 — Configure GBrain domain

Dokploy UI → gbrain Compose → **Domains** tab → Add Domain:
- Host: `brain.yourdomain.eu`
- Service: `gbrain`
- Port: `8787`
- HTTPS: enabled, Let's Encrypt

### Step 2.5 — Deploy GBrain

Click **Deploy**. Expected healthy boot log:
```
[gbrain] Supabase Postgres is ready.
[gbrain] First run — initialising schema...
[gbrain] Init complete.
[gbrain] Starting MCP server on port 8787...
```

---

## Part 3 — Post-deploy setup

### Step 3.1 — Create Bearer tokens

Dokploy UI → gbrain Compose → **gbrain** service → **Terminal** tab:

```bash
bun /gbrain/src/commands/auth.ts create "claude-code"
bun /gbrain/src/commands/auth.ts create "cowork"
bun /gbrain/src/commands/auth.ts create "hermes"
bun /gbrain/src/commands/auth.ts create "openclaw"
bun /gbrain/src/commands/auth.ts list
```

### Step 3.2 — Schedule Jobs

Dokploy UI → gbrain Compose service → **Schedule Jobs** tab → **Add Job**.
Type = **Compose**, Service = `gbrain`, Shell = `sh`, Timezone = `Europe/Rome`.

| Name | Cron | Command |
|---|---|---|
| `gbrain-sync` | `*/15 * * * *` | `gbrain sync --repo /brain && gbrain embed --stale` |
| `gbrain-dream` | `0 2 * * *` | `gbrain dream` |
| `gbrain-prune` | `0 1 * * *` | `gbrain jobs prune --older-than 30d` |
| `gbrain-doctor` | `0 3 * * 0` | `gbrain doctor --json && gbrain embed --stale` |

### Step 3.3 — Connect clients

**Claude Code (Mac Mini):**
```bash
claude mcp add gbrain -t http https://brain.yourdomain.eu/mcp \
  -H "Authorization: Bearer TOKEN"
```

**Claude Cowork:** Organization Settings → Connectors → Add
- URL: `https://brain.yourdomain.eu/mcp`
- Auth: Bearer token

**Hermes / OpenClaw (same Dokploy server):**
Internal — no Traefik needed: `http://gbrain:8787/mcp`

### Step 3.4 — Import brain content

Dokploy UI → gbrain Compose → **gbrain** service → **Terminal**:
```bash
gbrain import /brain --no-embed
gbrain embed --stale
gbrain extract links --source db
gbrain extract timeline --source db
gbrain stats
```

---

## Day-to-day operations

All via Dokploy UI → gbrain Compose → gbrain service → Terminal:
```bash
gbrain doctor
gbrain stats
gbrain jobs list
bun /gbrain/src/commands/auth.ts list
```

## Upgrade GBrain

Dokploy UI → gbrain Compose → click **Deploy** (rebuilds from latest master). Then Terminal:
```bash
gbrain init --url "$DATABASE_URL"
gbrain post-upgrade
```
