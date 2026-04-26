#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Postgres init script — runs once on first container start.
# Creates postgres.gbrain superuser with dot-notation username matching
# the Supabase pooler URL format that GBrain's init validator expects.
# ─────────────────────────────────────────────────────────────────────────────
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  -- Extensions required by GBrain hybrid search
  CREATE EXTENSION IF NOT EXISTS vector;
  CREATE EXTENSION IF NOT EXISTS pg_trgm;

  -- User with dot-notation username (postgres.gbrain) matching Supabase
  -- pooler URL format. GBrain's URL validator expects this pattern.
  -- SUPERUSER required for extension creation during gbrain init.
  CREATE USER "postgres.gbrain" WITH SUPERUSER PASSWORD '${POSTGRES_PASSWORD}';
  GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO "postgres.gbrain";
EOSQL
