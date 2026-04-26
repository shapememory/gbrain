# GBrain — Dokploy Deployment

One compose file. One Dokploy project. Three services.

```
postgres       pgvector/pgvector:pg16    Database            internal
gbrain         built here                MCP server :8787    brain.shapememory.eu
gbrain-worker  built here                Minions supervisor  internal
```

**Why this works with GBrain's validator:**
GBrain's `init --url` expects a Supabase pooler URL format where the username
contains a dot (`postgres.tenantid`). The `init.sh` script creates a PostgreSQL
superuser named `postgres.gbrain` on first boot. The DATABASE_URL then uses
`postgres.gbrain` as the username, satisfying the validator without requiring
any Supabase services.

---

## Before deploying

In Dokploy → server → **Terminal**:
```sh
mkdir -p /var/www/hilvara/gbrain/postgres
mkdir -p /var/www/hilvara/gbrain/brain
mkdir -p /var/www/hilvara/gbrain/config
```

DNS: A record `brain.shapememory.eu` → your Hetzner IP.

---

## Step 1 — Create Compose service

Dokploy UI → **New Project** (name: `gbrain`) → **New Service** → **Compose**:
- Compose Type: `Docker Compose`
- Provider: GitHub → this repo → branch `main`
- Compose Path: `./docker-compose.yml`
- **Save**

---

## Step 2 — Environment variables

Dokploy UI → gbrain Compose → **Environment** tab:

| Variable | Value | Notes |
|---|---|---|
| `POSTGRES_PASSWORD` | strong password (min 24 chars) | Used for both postgres and postgres.gbrain users |
| `OPENAI_API_KEY` | `sk-...` | Required — vector embeddings |
| `ANTHROPIC_API_KEY` | `sk-ant-...` | Recommended — query expansion |
| `GROQ_API_KEY` | leave blank | Optional — voice transcription |
| `GBRAIN_DOMAIN` | `brain.shapememory.eu` | Public MCP endpoint |
| `MINIONS_CONCURRENCY` | `4` | Parallel background jobs |

---

## Step 3 — Domain

Dokploy UI → **Domains** tab → **Add Domain**:

| Field | Value |
|---|---|
| Host | `brain.shapememory.eu` |
| Service | `gbrain` |
| Port | `8787` |
| HTTPS | enabled, Let's Encrypt |

> Using Domains UI: remove the `labels:` block from `docker-compose.yml`.

---

## Step 4 — Deploy

Click **Deploy**. Expected log:
```
[gbrain] Waiting for Postgres...
[gbrain] Postgres ready.
[gbrain] First run — initialising schema...
[gbrain] Init complete.
[gbrain] Starting MCP server on port 8787...
[worker] Postgres ready.
[worker] gbrain ready.
[worker] Starting Minions supervisor (concurrency=4)...
```

---

## Step 5 — Create Bearer tokens

Dokploy → Compose → **gbrain** service → **Terminal**:
```sh
bun /gbrain/src/commands/auth.ts create "claude-code"
bun /gbrain/src/commands/auth.ts create "cowork"
bun /gbrain/src/commands/auth.ts create "hermes"
bun /gbrain/src/commands/auth.ts create "openclaw"
bun /gbrain/src/commands/auth.ts list
```

---

## Step 6 — Schedule Jobs

Dokploy → Compose → **Schedule Jobs** → **Add Job**  
Type: Compose · Service: `gbrain` · Shell: `sh` · Timezone: `Europe/Rome`

| Name | Cron | Command |
|---|---|---|
| `gbrain-sync` | `*/15 * * * *` | `gbrain sync --repo /brain && gbrain embed --stale` |
| `gbrain-dream` | `0 2 * * *` | `gbrain dream` |
| `gbrain-prune` | `0 1 * * *` | `gbrain jobs prune --older-than 30d` |
| `gbrain-doctor` | `0 3 * * 0` | `gbrain doctor --json && gbrain embed --stale` |

---

## Step 7 — Connect clients

**Claude Code (Mac Mini)**:
```sh
claude mcp add gbrain -t http https://brain.shapememory.eu/mcp \
  -H "Authorization: Bearer TOKEN"
```

**Claude Cowork**: Org Settings → Connectors → URL: `https://brain.shapememory.eu/mcp`

**Hermes / OpenClaw (same server)**: `http://gbrain:8787/mcp`

---

## Step 8 — Import brain content

Dokploy → **gbrain** service → **Terminal**:
```sh
gbrain import /brain --no-embed
gbrain embed --stale
gbrain extract links --source db
gbrain extract timeline --source db
gbrain stats
```

---

## Operations

```sh
gbrain doctor
gbrain stats
gbrain jobs list
bun /gbrain/src/commands/auth.ts list
```

## Upgrade

Dokploy → **Deploy**. Then Terminal:
```sh
gbrain init --url "$DATABASE_URL"
gbrain post-upgrade
```
