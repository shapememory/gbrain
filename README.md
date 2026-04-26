# GBrain — Dokploy Deployment

Self-hosted GBrain on Hetzner via Dokploy.
3 services + Dokploy's native scheduler for maintenance jobs.

```
postgres       pgvector/pgvector:pg16   DB + vector search       (internal)
gbrain         built here               MCP HTTP server :8787    (Traefik)
gbrain-worker  built here               Minions job supervisor   (internal)

Scheduled jobs → Dokploy Schedule Jobs UI (no cron container needed)
```

## File structure

```
gbrain-deploy/
├── Dockerfile             Single image for both gbrain services
├── docker-compose.yml     3 services: postgres, gbrain, gbrain-worker
├── entrypoint.sh          MCP server: postgres wait + init + gbrain serve
├── worker-entrypoint.sh   Minions: postgres wait + jobs supervisor
├── init-pgvector.sql      Enables vector + pg_trgm on first Postgres start
├── .env.example           Copy to .env for local testing
└── README.md
```

---

## Step 1 — Prepare host directories and push to GitHub

Create the persistent storage directories on the Hetzner server before first deploy:

```bash
mkdir -p /var/www/hilvara/gbrain/{postgres,brain,config}
```

Then push this directory to a GitHub repo (public or private).

---

## Step 2 — Create Dokploy Compose service

1. Dokploy UI → **New Project** → **New Service** → **Compose**
2. Compose Type: **Docker Compose**
3. Provider: **GitHub** → select this repo → branch: `main`
4. Compose Path: `./docker-compose.yml`
5. Click **Save**

---

## Step 3 — Set environment variables

Dokploy UI → your Compose service → **Environment** tab.

Add each variable as a separate row (Name / Value):

| Name | Value | Notes |
|---|---|---|
| `POSTGRES_DB` | `gbrain` | |
| `POSTGRES_USER` | `gbrain` | |
| `POSTGRES_PASSWORD` | `your_strong_password` | Use a generated password |
| `OPENAI_API_KEY` | `sk-...` | Required — powers vector embeddings |
| `ANTHROPIC_API_KEY` | `sk-ant-...` | Recommended — improves query expansion |
| `GROQ_API_KEY` | *(leave blank if unused)* | Optional — voice transcription |
| `MINIONS_CONCURRENCY` | `4` | Parallel background jobs |
| `GBRAIN_DOMAIN` | `brain.yourdomain.eu` | Only needed if keeping manual Traefik labels (see Step 4) |

Click **Save**. Dokploy injects these into all services at deploy time — no `.env` file needed anywhere.

---

## Step 4 — Configure domain

Dokploy UI → **Domains** tab → **Add Domain**:

| Field | Value |
|---|---|
| Host | `brain.yourdomain.eu` |
| Service | `gbrain` |
| Container Port | `8787` |
| HTTPS | enabled |
| Certificate | Let's Encrypt |

Save. Dokploy injects Traefik labels automatically.

> If you configured the domain this way, remove the entire `labels:` block
> from `docker-compose.yml` to avoid duplicate label conflicts.

---

## Step 5 — Deploy

Click **Deploy**. Watch the **Logs** tab.

First deploy takes ~3–4 minutes (git clone + `bun install` across 3 image builds).
Subsequent deploys hit the layer cache and are much faster.

---

## Step 6 — Create Bearer tokens (run once after healthy boot)

In Dokploy UI → **gbrain** service → **Terminal** tab (or via SSH):

```bash
bun /gbrain/src/commands/auth.ts create "claude-code"
bun /gbrain/src/commands/auth.ts create "cowork"
bun /gbrain/src/commands/auth.ts create "hermes"
bun /gbrain/src/commands/auth.ts create "openclaw"

# Confirm
bun /gbrain/src/commands/auth.ts list
```

---

## Step 7 — Schedule Jobs (replaces cron container)

Dokploy UI → your Compose service → **Schedule Jobs** tab → **Add Job**.

For each job: set Type = **Compose**, select service = `gbrain`, set the cron expression and command. Dokploy runs the command inside the container via docker exec and logs every execution.

Add these 4 jobs:

### Job 1 — Brain sync (every 15 min)
| Field | Value |
|---|---|
| Name | `gbrain-sync` |
| Schedule Type | Compose |
| Service | `gbrain` |
| Cron | `*/15 * * * *` |
| Command | `gbrain sync --repo /brain && gbrain embed --stale` |
| Shell | `sh` |

### Job 2 — Dream cycle (nightly 02:00)
| Field | Value |
|---|---|
| Name | `gbrain-dream` |
| Schedule Type | Compose |
| Service | `gbrain` |
| Cron | `0 2 * * *` |
| Command | `gbrain dream` |
| Shell | `sh` |

### Job 3 — Job queue prune (daily 01:00)
| Field | Value |
|---|---|
| Name | `gbrain-prune` |
| Schedule Type | Compose |
| Service | `gbrain` |
| Cron | `0 1 * * *` |
| Command | `gbrain jobs prune --older-than 30d` |
| Shell | `sh` |

### Job 4 — Health check (weekly Sunday 03:00)
| Field | Value |
|---|---|
| Name | `gbrain-doctor` |
| Schedule Type | Compose |
| Service | `gbrain` |
| Cron | `0 3 * * 0` |
| Command | `gbrain doctor --json && gbrain embed --stale` |
| Shell | `sh` |

> **Timezone**: set in Dokploy's Schedule Job UI per job. Use `Europe/Rome`.

---

## Step 8 — Connect your clients

**Claude Code (Mac Mini):**
```bash
claude mcp add gbrain -t http https://brain.yourdomain.eu/mcp \
  -H "Authorization: Bearer TOKEN_FROM_STEP_6"
```

**Claude Cowork:**
Organization Settings → Connectors → Add:
- URL: `https://brain.yourdomain.eu/mcp`
- Auth: Bearer `TOKEN_COWORK`

**Hermes / OpenClaw (same Dokploy server):**
Can hit gbrain on the internal network without going through Traefik:
```
http://gbrain:8787/mcp
```

---

## Step 9 — Import your brain content

Add your markdown files to the `brain-data` volume, then trigger a manual import:

```bash
# In Dokploy Terminal tab for gbrain service:
gbrain import /brain --no-embed
gbrain embed --stale
gbrain extract links --source db
gbrain extract timeline --source db
gbrain stats
```

---

## Day-to-day operations

```bash
# All commands run in Dokploy → gbrain service → Terminal tab

gbrain doctor            # full health check
gbrain stats             # brain size, links, embeddings
gbrain dream             # run dream cycle manually
gbrain jobs list         # Minions queue
gbrain jobs stats        # job health dashboard
bun /gbrain/src/commands/auth.ts list   # list Bearer tokens
```

---

## Upgrade GBrain

In Dokploy UI → click **Deploy** (rebuilds image from latest master). Then:

```bash
gbrain init          # schema migrations (idempotent)
gbrain post-upgrade  # migration notes for this version
```

To pin a specific version, change `GBRAIN_REF: master` → `GBRAIN_REF: v0.19.0`
in docker-compose.yml before redeploying.
