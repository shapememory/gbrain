#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# GBrain Minions Worker entrypoint
# ─────────────────────────────────────────────────────────────────────────────
set -e

log() { echo "[worker] $*"; }

# ── 1. Wait for Postgres ──────────────────────────────────────────────────────
log "Waiting for Postgres..."
until pg_isready -h postgres -U postgres -q; do sleep 2; done
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
  && log "gbrain slow to start — proceeding anyway" \
  || log "gbrain ready."

# ── 3. Verify Minions queue ───────────────────────────────────────────────────
log "Running gbrain jobs smoke..."
gbrain jobs smoke 2>&1 || log "Smoke warnings — proceeding"

# ── 4. Start supervisor ───────────────────────────────────────────────────────
log "Starting Minions supervisor (concurrency=${MINIONS_CONCURRENCY:-4})..."
exec gbrain jobs supervisor --concurrency "${MINIONS_CONCURRENCY:-4}"
