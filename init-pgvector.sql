-- Runs automatically on first Postgres container start (docker-entrypoint-initdb.d)
-- Enables extensions required by GBrain's hybrid search

CREATE EXTENSION IF NOT EXISTS vector;    -- pgvector: HNSW cosine vector search
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- trigram index: fuzzy keyword search
