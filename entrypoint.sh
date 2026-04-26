#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# GBrain MCP Server entrypoint
# Role: wait for Postgres → first-run init → gbrain serve
# ─────────────────────────────────────────────────────────────────────────────
set -e

INIT_MARKER="/root/.gbrain/.initialized"

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

# ── 2. First-run: init schema + import brain ──────────────────────────────────
if [ ! -f "$INIT_MARKER" ]; then
  log "First run detected — running gbrain init --supabase..."
  gbrain init --supabase

  # Import markdown files if the brain volume already has content
  if find /brain -name "*.md" -maxdepth 3 2>/dev/null | grep -q .; then
    log "Found markdown files in /brain — importing..."
    gbrain import /brain --no-embed
    gbrain embed --stale
    gbrain extract links --source db
    gbrain extract timeline --source db
    log "Initial import complete. Running gbrain stats..."
    gbrain stats
  else
    log "Brain volume is empty. Add markdown files to /brain and run:"
    log "  docker compose exec gbrain gbrain import /brain --no-embed"
  fi

  touch "$INIT_MARKER"
  log "Init complete."
else
  # On every restart: apply any pending schema migrations (idempotent)
  log "Applying schema migrations (idempotent)..."
  gbrain init --supabase 2>&1 | grep -v "^$" || true
fi

# ── 3. Quick health check ─────────────────────────────────────────────────────
log "Running gbrain doctor --fast..."
gbrain doctor --fast 2>&1 || log "Warning: doctor reported issues — check logs"

# ── 4. Start MCP HTTP server ──────────────────────────────────────────────────
log "Starting MCP server on port ${GBRAIN_PORT:-8787}..."
exec gbrain serve
