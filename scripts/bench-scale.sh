#!/usr/bin/env bash
# Scale bench — drawers grow; dream compresses hot set with TurboQuant-style quant.
#
# Default N=500 (quick). Serious: N=10000 or N=100000 (long seed — embeddings dominate).
#
# Usage:
#   ./scripts/bench-scale.sh
#   N=2000 HOT_BUDGET=200 ./scripts/bench-scale.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${MEMXT_BIN:-$ROOT/zig-out/bin/memxt}"
MODEL="${MEMXT_MODEL:-$ROOT/lib/minilm.gguf}"
DB="${MEMXT_DB:-/tmp/memxt-scale-bench.db}"
N="${N:-500}"
HOT_BUDGET="${HOT_BUDGET:-100}"
export MEMXT_BIN="$BIN" MEMXT_DB="$DB" MEMXT_MODEL="$MODEL" MEMXT_WING=scale

echo "=== memxt scale bench ==="
echo "N=$N  HOT_BUDGET=$HOT_BUDGET  DB=$DB"
rm -f "$DB" "$DB-shm" "$DB-wal"
"$BIN" init >/dev/null

python3 - <<'PY'
import json, os, subprocess, time, sys
bin_path = os.environ["MEMXT_BIN"]
n = int(os.environ.get("N", "500"))
budget = int(os.environ.get("HOT_BUDGET", "100"))
db = os.environ["MEMXT_DB"]
env = os.environ.copy()
p = subprocess.Popen([bin_path, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)

def call(method, params=None, id=1):
    msg = {"jsonrpc": "2.0", "id": id, "method": method}
    if params is not None:
        msg["params"] = params
    p.stdin.write(json.dumps(msg) + "\n")
    p.stdin.flush()
    line = p.stdout.readline()
    if not line:
        raise RuntimeError("MCP died")
    return json.loads(line)

call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "scale", "version": "0"}})
call("tools/call", {"name": "memory_store", "arguments": {
    "content": "We use SQLite for the palace; dream enforces hot budget with 4-bit quant.",
    "wing": "scale", "room": "decisions"
}}, id=2)

t0 = time.time()
for i in range(n):
    room = "notes" if (i % 10) else "decisions"
    content = (
        f"Scale drawer {i}: module_{i % 50} error E{i % 97:02d}. "
        + ("We use pattern stable." if (i % 10) == 0 else "Routine note for volume.")
    )
    call("tools/call", {"name": "memory_store", "arguments": {
        "content": content, "wing": "scale", "room": room
    }}, id=100 + i)
    if (i + 1) % max(1, n // 5) == 0:
        print(f"  seeded {i+1}/{n}", flush=True)
seed_s = time.time() - t0
print(f"SEED_TIME_S\t{seed_s:.2f}")
print(f"SEED_RATE\t{n / max(seed_s, 1e-6):.1f} drawers/s")

t0 = time.time()
for i in range(15):
    call("tools/call", {"name": "memory_search", "arguments": {
        "query": f"module_{i % 50} error", "wing": "scale", "limit": 5
    }}, id=1000 + i)
print(f"SEARCH_WARM_S\t{(time.time() - t0) / 15:.4f}")

t0 = time.time()
r = call("tools/call", {"name": "memory_dream", "arguments": {"budget": budget}}, id=2000)
print(f"DREAM_TIME_S\t{time.time() - t0:.2f}")
text = r.get("result", {}).get("content", [{}])[0].get("text", "")
for line in text.splitlines():
    if any(k in line for k in ("Hot vectors after", "Quantized", "Demoted", "Drawers total")):
        print("DREAM\t" + line.strip())

t0 = time.time()
for i in range(15):
    call("tools/call", {"name": "memory_search", "arguments": {
        "query": f"module_{i % 50} pattern", "wing": "scale", "limit": 5
    }}, id=3000 + i)
print(f"SEARCH_AFTER_DREAM_S\t{(time.time() - t0) / 15:.4f}")

t0 = time.time()
for _ in range(30):
    call("tools/call", {"name": "memory_wake_up", "arguments": {"wing": "scale"}}, id=4000)
print(f"WAKEUP_S\t{(time.time() - t0) / 30:.4f}")

sz = os.path.getsize(db) if os.path.exists(db) else 0
print(f"DB_BYTES\t{sz}")
print(f"DB_MB\t{sz / 1024 / 1024:.2f}")
print("SCALE_BENCH_OK")
p.terminate()
PY

echo ""
"$BIN" inspect | head -28
echo ""
echo "Scale bench done. Stress: N=10000 HOT_BUDGET=500 ./scripts/bench-scale.sh"
