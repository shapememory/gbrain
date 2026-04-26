#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# GBrain MCP Server entrypoint
# Role: wait for Postgres → write config → init schema → gbrain serve
# ─────────────────────────────────────────────────────────────────────────────
set -e

INIT_MARKER="/root/.gbrain/.initialized"
CONFIG_FILE="/root/.gbrain/config.json"

log() { echo "[gbrain] $*"; }

# ── 1. Wait for Postgres ──────────────────────────────────────────────────────
log "Waiting for Postgres at ${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}..."
until pg_isready \
    -h "${POSTGRES_HOST:-postgres}" \
    -p "${POSTGRES_PORT:-5432}" \
    -U "${POSTGRES_USER:-gbrain}" -q; do
  sleep 2
done
log "Postgres is ready."

# ── 2. Write config.json from DATABASE_URL ────────────────────────────────────
# gbrain init --url rejects plain postgresql:// URLs (expects Supabase pooler
# format). Writing config.json directly bypasses the URL validator entirely.
# gbrain serve reads DATABASE_URL from env anyway — this just ensures gbrain
# init also finds the correct engine config when applying schema migrations.
mkdir -p /root/.gbrain
cat > "$CONFIG_FILE" <<GBCONFIG
{
  "engine": "postgres",
  "databaseUrl": "${DATABASE_URL}"
}
GBCONFIG
log "Config written: engine=postgres databaseUrl=postgresql://...@${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}/..."

# ── 3. Schema init / migrations ───────────────────────────────────────────────
if [ ! -f "$INIT_MARKER" ]; then
  log "First run — applying schema..."
  gbrain init

  if find /brain -name "*.md" -maxdepth 3 2>/dev/null | grep -q .; then
    log "Brain volume has content — importing..."
    gbrain import /brain --no-embed
    gbrain embed --stale
    gbrain extract links --source db
    gbrain extract timeline --source db
    gbrain stats
  else
    log "Brain volume is empty — add markdown files to /var/www/hilvara/gbrain/brain/"
  fi

  touch "$INIT_MARKER"
  log "Init complete."
else
  log "Applying schema migrations (idempotent)..."
  gbrain init 2>&1 | grep -v "^$" || true
fi

# ── 4. Health check ───────────────────────────────────────────────────────────
log "Running gbrain doctor --fast..."
gbrain doctor --fast 2>&1 || log "Warning: doctor reported issues — check logs"

# ── 5. Start MCP HTTP server ──────────────────────────────────────────────────
log "Starting MCP server on port ${GBRAIN_PORT:-8787}..."
exec gbrain serve
