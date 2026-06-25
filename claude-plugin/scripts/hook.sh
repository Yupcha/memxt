#!/usr/bin/env bash
# Bridge a Claude Code hook event to memxt, pinning the global palace
# and embedding model so memory is consistent across every project. The hook
# JSON arrives on stdin and the response goes to stdout — we just pass through.
export MEMXT_DB="${MEMXT_DB:-$HOME/.memxt/palace.db}"
export MEMXT_MODEL="${MEMXT_MODEL:-$HOME/.memxt/lib/minilm.gguf}"
BIN="${MEMXT_BIN:-$HOME/.memxt/bin/memxt}"

# If the binary isn't installed, stay silent and let the session continue.
[ -x "$BIN" ] || { echo '{}'; exit 0; }
exec "$BIN" hook
