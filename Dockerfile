# ─────────────────────────────────────────────────────────────────────────────
# GBrain — single image, two roles:
#   gbrain        → /entrypoint.sh          (MCP HTTP server)
#   gbrain-worker → /worker-entrypoint.sh   (Minions job supervisor)
#
# Scheduled maintenance (sync, dream, doctor) is handled by Dokploy's
# built-in Schedule Jobs feature — no cron container needed.
#
# Build arg GBRAIN_REF lets you pin to a specific tag or commit.
# Default: master (latest). For production pin: e.g. v0.19.0
# ─────────────────────────────────────────────────────────────────────────────

FROM oven/bun:1 AS builder

WORKDIR /gbrain

RUN apt-get update && apt-get install -y git ca-certificates --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

ARG GBRAIN_REF=master
RUN git clone --depth 1 --branch ${GBRAIN_REF} \
    https://github.com/garrytan/gbrain.git . \
    && bun install --frozen-lockfile

# ─────────────────────────────────────────────────────────────────────────────
# Runtime — keep full source so skills/**, docs/**, recipes/** are on-disk.
# GBrain reads skill markdown files at runtime; a compiled binary alone fails.
# ─────────────────────────────────────────────────────────────────────────────
FROM oven/bun:1

LABEL org.opencontainers.image.title="GBrain"
LABEL org.opencontainers.image.source="https://github.com/garrytan/gbrain"

# System tools: pg_isready (wait for postgres), curl (health checks), git (sync)
RUN apt-get update && apt-get install -y \
    ca-certificates curl git postgresql-client \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Copy gbrain source + installed node_modules from builder
COPY --from=builder /gbrain /gbrain
COPY --from=builder /root/.bun /root/.bun

ENV PATH="/root/.bun/bin:$PATH"
ENV HOME=/root
ENV GBRAIN_DIR=/gbrain

# Global `gbrain` command — thin shell wrapper around bun src/cli.ts
RUN printf '#!/bin/sh\nexec bun /gbrain/src/cli.ts "$@"\n' \
    > /usr/local/bin/gbrain && chmod +x /usr/local/bin/gbrain

# Brain repo (markdown knowledge files) — mounted as a volume by compose
VOLUME ["/brain"]

WORKDIR /brain

# Copy entrypoints
COPY entrypoint.sh        /entrypoint.sh
COPY worker-entrypoint.sh /worker-entrypoint.sh
RUN chmod +x /entrypoint.sh /worker-entrypoint.sh

EXPOSE 8787

# Default role: MCP server. Overridden per-service in docker-compose.yml.
ENTRYPOINT ["/entrypoint.sh"]
