#!/usr/bin/env bash
# End-to-end integration tests for the memxt binary: directory mining,
# semantic ranking, the MCP protocol (store -> recall), the Claude Code hooks,
# and schema versioning. Exercises the REAL binary, not unit-level mocks.
#
# Usage: scripts/integration-test.sh [path-to-binary]
#   BIN defaults to ./zig-out/bin/memxt
#   MEMXT_MODEL defaults to ./lib/minilm.gguf
set -uo pipefail

BIN="${1:-./zig-out/bin/memxt}"
export MEMXT_MODEL="${MEMXT_MODEL:-$PWD/lib/minilm.gguf}"
WORK="$(mktemp -d)"
export MEMXT_DB="$WORK/palace.db"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31m✗ %s\033[0m\n" "$1"; FAIL=$((FAIL+1)); }
have() { echo "$1" | grep -q -- "$2"; }

[ -x "$BIN" ] || { echo "binary not found/executable: $BIN"; exit 1; }
[ -f "$MEMXT_MODEL" ] || { echo "model not found: $MEMXT_MODEL"; exit 1; }

echo "memxt integration tests"
echo "  bin:   $BIN"
echo "  model: $MEMXT_MODEL"

"$BIN" init >/dev/null 2>&1

# 1) schema version is stamped
ver=$(sqlite3 "$MEMXT_DB" "PRAGMA user_version;" 2>/dev/null || echo "")
[ "$ver" = "1" ] && ok "schema version stamped (=1)" || bad "schema version not stamped (got '$ver')"

# 2) directory mining ingests multiple files
CORPUS="$WORK/corpus"; mkdir -p "$CORPUS"
printf 'The mitochondria is the powerhouse of the cell; respiration makes ATP energy.\n' > "$CORPUS/biology.txt"
printf 'To pull a good espresso, grind the beans fine and tamp evenly before extraction.\n' > "$CORPUS/coffee.txt"
printf 'A balanced binary search tree gives O(log n) lookups; rebalance to avoid linear worst case.\n' > "$CORPUS/algorithms.txt"
printf 'The French Revolution began in 1789 and led to the rise of Napoleon Bonaparte.\n' > "$CORPUS/history.txt"
mine_out=$("$BIN" mine "$CORPUS" testwing 2>&1)
have "$mine_out" "Drawers created: 4" && ok "directory mine ingested 4 files" || bad "directory mine wrong drawer count: $(echo "$mine_out" | grep Drawers)"

# 3) semantic ranking: paraphrase queries (no shared keywords) hit the right file
rank() { "$BIN" search "$1" 2>&1 | grep -m1 "Source:" | sed 's/.*Source: //'; }
check_rank() { local got; got=$(rank "$1"); [ "$got" = "$2" ] && ok "rank: '$1' -> $2" || bad "rank: '$1' -> got '$got', want $2"; }
check_rank "how do biological cells produce energy" "biology.txt"
check_rank "brewing a great cup of coffee"          "coffee.txt"
check_rank "fast data structure for lookups"        "algorithms.txt"
check_rank "Napoleon and the revolution in France"  "history.txt"

# 4) MCP protocol: initialize, tools/list, and a store -> recall round-trip
mcp_out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_store","arguments":{"content":"The deploy key id is QUASAR-77 and must never be logged."}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"what is the deploy key id"}}}' \
  | "$BIN" mcp 2>/dev/null)
have "$mcp_out" '"protocolVersion":"2025-11-25"' && ok "MCP initialize echoes protocol version" || bad "MCP initialize bad"
# tools/list is one JSON line, so count occurrences (grep -o), not matching lines.
[ "$(echo "$mcp_out" | grep -o 'inputSchema' | wc -l | tr -d ' ')" = "4" ] && ok "MCP tools/list exposes 4 tools" || bad "MCP tools/list wrong tool count"
have "$mcp_out" "QUASAR-77" && ok "MCP store -> recall round-trip" || bad "MCP store/recall failed"

# 5) hooks: SessionStart injects context; PreCompact saves the transcript tail
ss=$(echo '{"hook_event_name":"SessionStart","source":"startup"}' | "$BIN" hook 2>/dev/null)
have "$ss" "additionalContext" && ok "SessionStart hook injects context" || bad "SessionStart hook output bad"

cat > "$WORK/transcript.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"Decide the cache backend."}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"We will use Redis over Memcached because we need pub/sub for live presence."}]}}
EOF
echo "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"transcript_path\":\"$WORK/transcript.jsonl\"}" | "$BIN" hook >/dev/null 2>&1
hook_rc=$?
[ "$hook_rc" = "0" ] && ok "PreCompact hook exits 0 (no teardown abort)" || bad "PreCompact hook exit $hook_rc"
recall=$("$BIN" search "which cache backend did we choose" 2>&1)
have "$recall" "Redis" && ok "PreCompact auto-saved content is recallable" || bad "PreCompact auto-save not recalled"

# 6) adversarial MCP input must not crash the server (memory-safety regression guard)
adv=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":5}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"x","limit":9999999999}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"x","limit":-5}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"2024-11-05\",\"evil\":\"x"}}' \
  | "$BIN" mcp 2>/dev/null)
advrc=$?
[ "$advrc" = "0" ] && ok "MCP survives adversarial input (no crash)" || bad "MCP crashed on adversarial input (exit $advrc)"
have "$adv" "evil" && bad "protocolVersion injection NOT neutralized" || ok "protocolVersion injection neutralized"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "integration: $PASS passed, 0 failed"
  exit 0
else
  echo "integration: $PASS passed, $FAIL FAILED"
  exit 1
fi
