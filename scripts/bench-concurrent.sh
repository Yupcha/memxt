#!/usr/bin/env bash
# Concurrent write stress — a fleet of N parallel MCP writers share one palace DB.
#
# Each worker is a separate `memxt mcp` process (own SQLite connection) doing
# memory_store (some scratch), memory_promote, and memory_search against the
# same palace. Asserts: every RPC succeeds, every unique drawer lands, per-worker
# `source` attribution is recorded, and PRAGMA integrity_check passes at the end.
#
# Usage:
#   ./scripts/bench-concurrent.sh
#   N=8 M=40 ./scripts/bench-concurrent.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${MEMXT_BIN:-$ROOT/zig-out/bin/memxt}"
MODEL="${MEMXT_MODEL:-$ROOT/lib/minilm.gguf}"
DB="${MEMXT_DB:-/tmp/memxt-concurrent-bench.db}"
N="${N:-6}"   # parallel workers
M="${M:-25}"  # stores per worker
export MEMXT_BIN="$BIN" MEMXT_DB="$DB" MEMXT_MODEL="$MODEL" MEMXT_WING=fleet

if [ ! -x "$BIN" ]; then
  echo "FAIL: memxt binary not found at $BIN (zig build first, or set MEMXT_BIN)" >&2
  exit 1
fi

echo "=== memxt concurrent write stress ==="
echo "N=$N workers  M=$M stores each  DB=$DB"
rm -f "$DB" "$DB-shm" "$DB-wal"
"$BIN" init >/dev/null

WORKER_PY="$(mktemp -t memxt-fleet-worker)"
trap 'rm -f "$WORKER_PY"' EXIT
cat >"$WORKER_PY" <<'PY'
import json, os, re, subprocess, sys

wid = int(sys.argv[1])
m = int(sys.argv[2])
env = os.environ.copy()
env["MEMXT_SOURCE"] = f"subagent:worker-{wid}"  # attribution via env default
p = subprocess.Popen([env["MEMXT_BIN"], "mcp"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env=env, text=True)

def call(method, params=None, id=1):
    msg = {"jsonrpc": "2.0", "id": id, "method": method}
    if params is not None:
        msg["params"] = params
    p.stdin.write(json.dumps(msg) + "\n")
    p.stdin.flush()
    line = p.stdout.readline()
    if not line:
        raise RuntimeError(f"worker {wid}: MCP died")
    r = json.loads(line)
    if "error" in r:
        raise RuntimeError(f"worker {wid}: RPC error: {r['error']}")
    return r

def tool_text(r):
    res = r.get("result", {})
    if res.get("isError"):
        raise RuntimeError(f"worker {wid}: tool errored: {res}")
    return res.get("content", [{}])[0].get("text", "")

call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": f"fleet-{wid}", "version": "0"}})

scratch_ids = []
for i in range(m):
    args = {
        "content": f"Fleet drawer w{wid}-{i}: module_{i % 7} chose pattern P{wid}-{i}.",
        "wing": "fleet",
        "room": "notes",
    }
    if i % 5 == 0:
        args["scratch"] = True
    text = tool_text(call("tools/call", {"name": "memory_store", "arguments": args}, id=100 + i))
    if "Stored" not in text:
        raise RuntimeError(f"worker {wid}: store {i} failed: {text!r}")
    mm = re.search(r"#(\d+)", text)
    if "scratch" in args and mm:
        scratch_ids.append(int(mm.group(1)))

# Promote one scratch memory to durable through the new tool.
if scratch_ids:
    text = tool_text(call("tools/call", {
        "name": "memory_promote", "arguments": {"id": scratch_ids[0]}
    }, id=9000))
    if "promoted" not in text and "already durable" not in text:
        raise RuntimeError(f"worker {wid}: promote failed: {text!r}")

# Interleave a few reads with everyone else's writes.
for i in range(3):
    call("tools/call", {"name": "memory_search", "arguments": {
        "query": f"module_{i} pattern", "wing": "fleet", "limit": 3
    }}, id=9100 + i)

p.stdin.close()
p.wait(timeout=30)
print(f"worker {wid}: OK ({m} stores, {len(scratch_ids)} scratch)")
PY

pids=()
for w in $(seq 1 "$N"); do
  python3 "$WORKER_PY" "$w" "$M" &
  pids+=($!)
done

fail=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done
if [ "$fail" -ne 0 ]; then
  echo "FAIL: one or more workers reported errors" >&2
  exit 1
fi

echo ""
echo "--- post-stress assertions ---"
IC="$(sqlite3 "$DB" 'PRAGMA integrity_check;')"
echo "integrity_check: $IC"
if [ "$IC" != "ok" ]; then
  echo "FAIL: palace corrupted under concurrent writers" >&2
  exit 1
fi

EXPECTED=$((N * M))
COUNT="$(sqlite3 "$DB" "SELECT COUNT(*) FROM drawers WHERE content LIKE 'Fleet drawer %';")"
echo "drawers stored: $COUNT / $EXPECTED"
if [ "$COUNT" -ne "$EXPECTED" ]; then
  echo "FAIL: dropped writes under contention ($COUNT != $EXPECTED)" >&2
  exit 1
fi

SOURCES="$(sqlite3 "$DB" "SELECT COUNT(DISTINCT source) FROM drawers WHERE source LIKE 'subagent:worker-%';")"
echo "distinct writer sources: $SOURCES / $N"
if [ "$SOURCES" -ne "$N" ]; then
  echo "FAIL: missing per-worker source attribution ($SOURCES != $N)" >&2
  exit 1
fi

SCRATCH="$(sqlite3 "$DB" "SELECT COUNT(*) FROM drawers WHERE expires_at IS NOT NULL;")"
echo "scratch (unpromoted, pending expiry): $SCRATCH"

echo ""
echo "CONCURRENT_BENCH_OK"
