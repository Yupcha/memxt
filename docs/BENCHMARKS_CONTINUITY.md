# Coding Continuity Bench

**Goal:** Prove memxt helps coding agents *remember decisions across sessions* without
re-reading the repo or calling a cloud memory API.

This is the benchmark we optimize for — not general chatbot LoCoMo alone.

## What it measures

| Check | Pass criteria |
|--|--|
| **Paraphrase recall** | Hybrid search finds the right decision when the query shares few keywords |
| **Wake-up profile** | Session brief includes stored project facts |
| **Profile tool** | `memory_profile` returns non-empty structured facts without needing a long search |

## Run

```bash
zig build --release=fast
./scripts/bench-continuity.sh
```

Expect:

```
SEARCH  …  PASS  (×4)
WAKEUP  PASS
PROFILE PASS
SCORE   6/6
```

## Why this matters for Claude Code

Real agent failure mode:

1. You decide “cart max 37 because ERP 0x5C”
2. Context is compacted
3. Next session the agent reopens the cart and “fixes” the cap

Continuity bench simulates step 3 with tools that only see memory — not the filesystem.

## Related

- Latency / footprint → [`BENCHMARK.md`](../BENCHMARK.md)
- Scale + quant after dream → [`scripts/bench-scale.sh`](../scripts/bench-scale.sh)
