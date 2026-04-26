#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# GBrain Minions Worker entrypoint
# Role: wait for Postgres + gbrain MCP → write config → start job supervisor
# ─────────────────────────────────────────────────────────────────────────────
set -e

log() { echo "[worker] $*"; }

# ── 1. Wait for Postgres ──────────────────────────────────────────────────────
log "Waiting for Postgres at ${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}..."
until pg_isready \
    -h "${POSTGRES_HOST:-postgres}" \
    -p "${POSTGRES_PORT:-5432}" \
    -U "${POSTGRES_USER:-gbrain}" -q; do
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

# ── 3. Write config.json ──────────────────────────────────────────────────────
# Same as gbrain service — ensures all gbrain commands use Postgres, not PGLite
mkdir -p /root/.gbrain
cat > /root/.gbrain/config.json <<GBCONFIG
{
  "engine": "postgres",
  "databaseUrl": "${DATABASE_URL}"
}
GBCONFIG
log "Config written: engine=postgres"

# ── 4. Verify Minions job queue ───────────────────────────────────────────────
log "Running gbrain jobs smoke..."
gbrain jobs smoke 2>&1 || log "Warning: jobs smoke check failed — proceeding"

# ── 5. Start Minions supervisor ───────────────────────────────────────────────
log "Starting Minions supervisor (concurrency=${MINIONS_CONCURRENCY:-4})..."
exec gbrain jobs supervisor --concurrency "${MINIONS_CONCURRENCY:-4}"
