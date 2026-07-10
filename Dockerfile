# Dockerfile — MCP inspection image (used by registries like Glama.ai to
# start the server and probe it over stdio).
#
# Not the recommended install path — memxt runs as a native binary with no
# container needed; see install.sh. For the CI build image see Dockerfile.ci.
#
#   docker build -t memxt .
#   docker run -i --rm memxt          # stdio JSON-RPC MCP server

FROM debian:bookworm-slim

# Release tag to install; "latest" tracks the newest GitHub release.
ARG MEMXT_VERSION=latest
# Set automatically by BuildKit; defaults to amd64 for plain `docker build`.
ARG TARGETARCH=amd64

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Prebuilt Linux binary from GitHub releases (glibc-linked — needs Debian/Ubuntu base).
RUN case "$TARGETARCH" in \
      amd64) MEMXT_ARCH=x86_64 ;; \
      arm64) MEMXT_ARCH=aarch64 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 2 ;; \
    esac \
    && if [ "$MEMXT_VERSION" = "latest" ]; then \
         URL="https://github.com/Yupcha/memxt/releases/latest/download/memxt-linux-${MEMXT_ARCH}.tar.gz"; \
       else \
         URL="https://github.com/Yupcha/memxt/releases/download/${MEMXT_VERSION}/memxt-linux-${MEMXT_ARCH}.tar.gz"; \
       fi \
    && curl -fsSL "$URL" | tar -xz -C /usr/local/bin memxt \
    && chmod 755 /usr/local/bin/memxt

# MiniLM-L6-v2 embedding model. Must stay a 384-dim model (matches
# EMBEDDING_DIM and the vec_drawers schema) — same source as install.sh.
RUN mkdir -p /data \
    && curl -fsSL -o /data/minilm.gguf \
       "https://huggingface.co/leliuga/all-MiniLM-L6-v2-GGUF/resolve/main/all-MiniLM-L6-v2.F16.gguf"

ENV MEMXT_MODEL=/data/minilm.gguf \
    MEMXT_DB=/data/memxt.db

RUN memxt init

CMD ["memxt", "mcp"]
