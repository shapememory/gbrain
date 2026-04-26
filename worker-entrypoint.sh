#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# GBrain Minions Worker entrypoint
# Role: wait for gbrain MCP server → start Minions supervisor
# ─────────────────────────────────────────────────────────────────────────────
set -e

log() { echo "[worker] $*"; }

# ── 1. Wait for Supabase Postgres ─────────────────────────────────────────────
DB_HOST=$(echo "$DATABASE_URL" | sed 's|.*@||' | sed 's|:.*||' | sed 's|/.*||')
DB_PORT=$(echo "$DATABASE_URL" | sed 's|.*:||' | sed 's|/.*||')
DB_USER=$(echo "$DATABASE_URL" | sed 's|.*://||' | sed 's|:.*||')

log "Waiting for Supabase Postgres at ${DB_HOST}:${DB_PORT:-5432}..."
until pg_isready -h "${DB_HOST}" -p "${DB_PORT:-5432}" -U "${DB_USER:-postgres}" -q; do
  sleep 2
done
log "Postgres ready."

# ── 2. Wait for gbrain MCP server ─────────────────────────────────────────────
log "Waiting for gbrain MCP server..."
RETRIES=30
while [ $RETRIES -gt 0 ]; do
  if curl -sf --max-time 3 "http://gbrain:${GBRAIN_PORT:-8787}/health" > /dev/null 2>&1; then
    break
  fi
  RETRIES=$((RETRIES - 1))
  sleep 3
done
[ $RETRIES -eq 0 ] \
  && log "Warning: gbrain did not respond in time — starting worker anyway" \
  || log "gbrain MCP server is ready."

# ── 3. Verify Minions job queue ───────────────────────────────────────────────
log "Running gbrain jobs smoke..."
gbrain jobs smoke 2>&1 || log "Warning: jobs smoke check failed — proceeding"

# ── 4. Start Minions supervisor ───────────────────────────────────────────────
log "Starting Minions supervisor (concurrency=${MINIONS_CONCURRENCY:-4})..."
exec gbrain jobs supervisor --concurrency "${MINIONS_CONCURRENCY:-4}"
