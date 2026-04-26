# ─────────────────────────────────────────────────────────────────────────────
# GBrain — single image, two roles:
#   gbrain        → /entrypoint.sh         (MCP HTTP server)
#   gbrain-worker → /worker-entrypoint.sh  (Minions supervisor)
# ─────────────────────────────────────────────────────────────────────────────

FROM oven/bun:1 AS builder

WORKDIR /gbrain

RUN apt-get update && apt-get install -y git ca-certificates --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

ARG GBRAIN_REF=master
RUN git clone --depth 1 --branch ${GBRAIN_REF} \
    https://github.com/garrytan/gbrain.git . \
    && bun install --frozen-lockfile

FROM oven/bun:1

LABEL org.opencontainers.image.title="GBrain"
LABEL org.opencontainers.image.source="https://github.com/garrytan/gbrain"

RUN apt-get update && apt-get install -y \
    ca-certificates curl git postgresql-client \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /gbrain /gbrain
COPY --from=builder /root/.bun /root/.bun

ENV PATH="/root/.bun/bin:$PATH"
ENV HOME=/root

RUN printf '#!/bin/sh\nexec bun /gbrain/src/cli.ts "$@"\n' \
    > /usr/local/bin/gbrain && chmod +x /usr/local/bin/gbrain

VOLUME ["/brain"]

# /gbrain is the installation dir — skills/, docs/, recipes/ resolve from here
WORKDIR /gbrain

COPY entrypoint.sh        /entrypoint.sh
COPY worker-entrypoint.sh /worker-entrypoint.sh
RUN chmod +x /entrypoint.sh /worker-entrypoint.sh

EXPOSE 8787
ENTRYPOINT ["/entrypoint.sh"]
