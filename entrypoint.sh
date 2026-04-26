#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# GBrain MCP Server entrypoint
# Role: wait for Supabase db → init schema → gbrain serve
# ─────────────────────────────────────────────────────────────────────────────
set -e

INIT_MARKER="/root/.gbrain/.initialized"

log() { echo "[gbrain] $*"; }

# ── 1. Wait for Supabase Postgres ─────────────────────────────────────────────
# Supabase db container is reachable as "supabase-db" via the supabase-gbrain
# network. Extract host from DATABASE_URL for pg_isready.
DB_HOST=$(echo "$DATABASE_URL" | sed 's|.*@||' | sed 's|:.*||' | sed 's|/.*||')
DB_PORT=$(echo "$DATABASE_URL" | sed 's|.*:||' | sed 's|/.*||')
DB_USER=$(echo "$DATABASE_URL" | sed 's|.*://||' | sed 's|:.*||')

log "Waiting for Supabase Postgres at ${DB_HOST}:${DB_PORT:-5432}..."
until pg_isready -h "${DB_HOST}" -p "${DB_PORT:-5432}" -U "${DB_USER:-postgres}" -q; do
  sleep 2
done
log "Supabase Postgres is ready."

# ── 2. Schema init / migrations ───────────────────────────────────────────────
if [ ! -f "$INIT_MARKER" ]; then
  log "First run — initialising schema..."
  gbrain init --url "$DATABASE_URL"

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
  gbrain init --url "$DATABASE_URL" 2>&1 | grep -v "^$" || true
fi

# ── 3. Health check ───────────────────────────────────────────────────────────
log "Running gbrain doctor --fast..."
gbrain doctor --fast 2>&1 || log "Warning: doctor reported issues — check logs"

# ── 4. Start MCP HTTP server ──────────────────────────────────────────────────
log "Starting MCP server on port ${GBRAIN_PORT:-8787}..."
exec gbrain serve
