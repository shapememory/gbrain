# GBrain — Dokploy Deployment

Self-hosted GBrain on Hetzner via Dokploy, connecting to a self-hosted Supabase instance.

```
[Supabase stack]          [GBrain stack]
  supabase-db   ←──────── gbrain          :8787  (Traefik)
  supabase-... (other)     gbrain-worker         (internal)

Shared network: supabase-gbrain
Scheduler:      Dokploy Schedule Jobs
```

## File structure

```
gbrain-deploy/
├── Dockerfile             Single image for both gbrain services
├── docker-compose.yml     2 services: gbrain, gbrain-worker
├── entrypoint.sh          Wait for Supabase db → init → gbrain serve
├── worker-entrypoint.sh   Wait for Supabase db + gbrain → Minions supervisor
└── README.md
```

---

## Step 1 — Deploy self-hosted Supabase

Supabase runs as a **separate Dokploy Compose project**. GBrain connects to
its database over a shared Docker network.

On your Hetzner server:

```bash
# Clone the official Supabase repo
git clone --depth 1 https://github.com/supabase/supabase
cd supabase/docker

# Copy and configure environment
cp .env.example .env
```

Edit `.env` — minimum required changes:

```env
POSTGRES_PASSWORD=your_strong_db_password
JWT_SECRET=your_32char_random_secret
ANON_KEY=<generate — see below>
SERVICE_ROLE_KEY=<generate — see below>
DASHBOARD_USERNAME=supabase
DASHBOARD_PASSWORD=your_dashboard_password
API_EXTERNAL_URL=https://supabase.yourdomain.eu
SITE_URL=https://supabase.yourdomain.eu
```

Generate `ANON_KEY` and `SERVICE_ROLE_KEY` using the Supabase key generator:
https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys

Point Supabase's data to your persistent path — in `docker-compose.yml`
change the db volumes section:
```yaml
db:
  volumes:
    - /var/www/hilvara/supabase/db:/var/lib/postgresql/data
```

Then deploy Supabase as a new Compose service in Dokploy pointing to your
`supabase/docker` directory.

---

## Step 2 — Create the shared Docker network

On the Hetzner server, run **once**:

```bash
docker network create supabase-gbrain
```

Then connect Supabase's `db` container to this network:

```bash
# After Supabase is running, connect its db container to the shared network.
# The container name follows the pattern: <project>-db-1
docker network connect supabase-gbrain supabase-db-1
```

> To make this permanent, add `supabase-gbrain` as an external network to
> Supabase's `docker-compose.yml` under the `db` service — so it reconnects
> automatically on every Supabase restart.

---

## Step 3 — Set environment variables (Dokploy Environment tab)

| Name | Value | Notes |
|---|---|---|
| `DATABASE_URL` | `postgresql://postgres:PASSWORD@supabase-db-1:5432/postgres` | Container name from Step 2 |
| `OPENAI_API_KEY` | `sk-...` | Required — vector embeddings |
| `ANTHROPIC_API_KEY` | `sk-ant-...` | Recommended — query expansion |
| `GROQ_API_KEY` | *(blank if unused)* | Optional — voice transcription |
| `GBRAIN_DOMAIN` | `brain.yourdomain.eu` | Your public domain |
| `MINIONS_CONCURRENCY` | `4` | Parallel background jobs |

---

## Step 4 — Prepare host directories and deploy

```bash
mkdir -p /var/www/hilvara/gbrain/{brain,config}
```

Push this repo to GitHub. In Dokploy:
1. **New Project → New Service → Compose → GitHub** → select this repo
2. Compose Path: `./docker-compose.yml`
3. **Domains** tab → service: `gbrain` → port: `8787` → HTTPS on
4. Click **Deploy**

---

## Step 5 — Create Bearer tokens

Dokploy UI → **gbrain** service → **Terminal** tab:

```bash
bun /gbrain/src/commands/auth.ts create "claude-code"
bun /gbrain/src/commands/auth.ts create "cowork"
bun /gbrain/src/commands/auth.ts create "hermes"
bun /gbrain/src/commands/auth.ts create "openclaw"

bun /gbrain/src/commands/auth.ts list
```

---

## Step 6 — Schedule Jobs

Dokploy → Compose service → **Schedule Jobs** → **Add Job**.
Type = **Compose**, Service = `gbrain`, Shell = `sh`, Timezone = `Europe/Rome`.

| Name | Cron | Command |
|---|---|---|
| `gbrain-sync` | `*/15 * * * *` | `gbrain sync --repo /brain && gbrain embed --stale` |
| `gbrain-dream` | `0 2 * * *` | `gbrain dream` |
| `gbrain-prune` | `0 1 * * *` | `gbrain jobs prune --older-than 30d` |
| `gbrain-doctor` | `0 3 * * 0` | `gbrain doctor --json && gbrain embed --stale` |

---

## Step 7 — Connect clients

**Claude Code (Mac Mini):**
```bash
claude mcp add gbrain -t http https://brain.yourdomain.eu/mcp \
  -H "Authorization: Bearer TOKEN"
```

**Claude Cowork:** Organization Settings → Connectors → Add
- URL: `https://brain.yourdomain.eu/mcp`
- Auth: Bearer token

**Hermes / OpenClaw (same server):** `http://gbrain:8787/mcp`

---

## Step 8 — Import brain content

```bash
gbrain import /brain --no-embed
gbrain embed --stale
gbrain extract links --source db
gbrain extract timeline --source db
gbrain stats
```

---

## Day-to-day

```bash
gbrain doctor
gbrain stats
gbrain dream
gbrain jobs list
bun /gbrain/src/commands/auth.ts list
```

## Upgrade GBrain

Click **Deploy** in Dokploy. Then in Terminal:
```bash
gbrain init --url "$DATABASE_URL"
gbrain post-upgrade
```
