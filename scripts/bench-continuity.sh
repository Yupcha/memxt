#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${MEMXT_BIN:-$ROOT/zig-out/bin/memxt}"
MODEL="${MEMXT_MODEL:-$ROOT/lib/minilm.gguf}"
DB="${MEMXT_DB:-/tmp/memxt-continuity-bench.db}"
export MEMXT_BIN="$BIN" MEMXT_DB="$DB" MEMXT_MODEL="$MODEL" MEMXT_WING=continuity

echo "=== Coding Continuity Bench ==="
rm -f "$DB" "$DB-shm" "$DB-wal"
"$BIN" init >/dev/null

python3 - <<'PY'
import json, os, subprocess, sys
bin_path = os.environ["MEMXT_BIN"]
env = os.environ.copy()
p = subprocess.Popen([bin_path, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)

def call(method, params=None, id=1):
    msg = {"jsonrpc": "2.0", "id": id, "method": method}
    if params is not None:
        msg["params"] = params
    p.stdin.write(json.dumps(msg) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())

call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "bench", "version": "0"}})
seeds = [
    "Cart is capped at 37 items because Brightwell ERP rejects larger orders with 0x5C error.",
    "We use SQLite over Postgres so agent memory is a single local file with zero ops.",
    "Never reintroduce Redis for session state in the shop service.",
    "Auth tokens live in HttpOnly cookies, not localStorage.",
]
for i, content in enumerate(seeds):
    call("tools/call", {"name": "memory_store", "arguments": {"content": content, "wing": "continuity", "room": "decisions"}}, id=10+i)

tests = [
    ("what is the maximum cart size and why", ["37", "0x5C", "Brightwell"]),
    ("why not postgres for storage", ["SQLite", "local"]),
    ("is redis allowed for sessions", ["Redis", "Never", "never"]),
    ("where should auth tokens be stored", ["HttpOnly", "cookie", "localStorage"]),
]
ok = 0
for qi, (q, needles) in enumerate(tests):
    r = call("tools/call", {"name": "memory_search", "arguments": {"query": q, "wing": "continuity", "mode": "hybrid", "limit": 3}}, id=100+qi)
    text = r.get("result", {}).get("content", [{}])[0].get("text", "")
    hit = any(n.lower() in text.lower() for n in needles)
    print(f"SEARCH\t{q}\t{'PASS' if hit else 'FAIL'}")
    ok += int(hit)

r = call("tools/call", {"name": "memory_wake_up", "arguments": {"wing": "continuity"}}, id=200)
wake = r.get("result", {}).get("content", [{}])[0].get("text", "")
wake_ok = any(x in wake for x in ("SQLite", "37", "project", "Redis", "HttpOnly"))
print(f"WAKEUP\t{'PASS' if wake_ok else 'FAIL'}")
ok += int(wake_ok)

r = call("tools/call", {"name": "memory_profile", "arguments": {"wing": "continuity"}}, id=201)
prof = r.get("result", {}).get("content", [{}])[0].get("text", "")
prof_ok = len(prof) > 40
print(f"PROFILE\t{'PASS' if prof_ok else 'FAIL'}")
ok += int(prof_ok)

total = len(tests) + 2
print(f"SCORE\t{ok}/{total}")
p.terminate()
sys.exit(0 if ok == total else 1)
PY
echo "DB=$DB"
