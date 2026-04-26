#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# GBrain MCP Server entrypoint
# DATABASE_URL uses postgres.gbrain username (Supabase dot-notation format)
# which satisfies GBrain's URL validator. gbrain init --url uses this directly.
# ─────────────────────────────────────────────────────────────────────────────
set -e

INIT_MARKER="/root/.gbrain/.initialized"
log() { echo "[gbrain] $*"; }

# ── 1. Wait for Postgres ──────────────────────────────────────────────────────
log "Waiting for Postgres..."
until pg_isready -h postgres -U postgres -q; do sleep 2; done
log "Postgres ready."

# ── 2. Schema init / migrations ───────────────────────────────────────────────
if [ ! -f "$INIT_MARKER" ]; then
  log "First run — initialising schema..."
  gbrain init --url "$DATABASE_URL"

  if find /brain -name "*.md" -maxdepth 3 2>/dev/null | grep -q .; then
    log "Importing brain content..."
    gbrain import /brain --no-embed
    gbrain embed --stale
    gbrain extract links --source db
    gbrain extract timeline --source db
    gbrain stats
  else
    log "Brain volume empty — add markdown to /var/www/hilvara/gbrain/brain/"
  fi

  touch "$INIT_MARKER"
  log "Init complete."
else
  log "Applying schema migrations..."
  gbrain init --url "$DATABASE_URL" 2>&1 | grep -v "^$" || true
fi

# ── 3. Health check ───────────────────────────────────────────────────────────
log "Running gbrain doctor --fast..."
gbrain doctor --fast 2>&1 || log "Doctor warnings present — continuing"

# ── 4. Start MCP server ───────────────────────────────────────────────────────
# Redirect stdin from /dev/null — in Docker there is no interactive stdin.
# Without this, gbrain serve (stdio MCP mode) exits immediately when it
# detects no input, causing an endless container restart loop.
# Start the HTTP gateway which keeps gbrain serve (stdio) alive internally
# and exposes it over HTTP on GBRAIN_PORT (default 8787).
# gbrain serve is stdio-only; the gateway is required for remote HTTP access.
log "Starting HTTP MCP gateway on port ${GBRAIN_PORT:-8787}..."
exec bun /gateway.ts < /dev/null
