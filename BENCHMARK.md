# ⏱️ memxt Benchmarks

Absolute performance of the real semantic engine (`llama.cpp` MiniLM-L6-v2 embeddings +
`sqlite-vec`). Hardware: Apple Silicon, macOS, Metal backend. Each command run cold
(fresh process) unless noted. Memory = peak resident set size.

> Earlier versions of this file reported a `0.59 s` mine of 1 171 drawers. That run used
> **placeholder vectors** (the embedder returned a constant dummy vector), so it measured
> I/O, not embedding. The numbers below are the real on-device semantic pipeline.

## 1. Latency

| Operation | Time | Peak RAM | Loads model? |
| --------- | ---- | -------- | ------------ |
| `stats` (cold start) | **0.01 s** | ~8 MB | no |
| `wake-up` (session context) | **0.01 s** | ~8 MB | no |
| `mine` — 15 files → 31 drawers | **~1.0 s** | ~100 MB | yes |
| `search` — one-shot CLI | **~0.55 s** | ~100 MB | yes (each call) |
| `search` — vector match only | **sub-ms** | — | model already resident |

The key distinction for agent use: the **CLI reloads the embedding model on every
invocation** (~0.5 s of that 0.55 s is Metal model init). The **MCP server loads the
model once and stays resident**, so per-query recall after warm-up is dominated by the
`sqlite-vec` match — sub-millisecond on these corpus sizes. Session `wake-up` never loads
the model at all, which is why it's 10 ms and runs on every session start.

## 2. Footprint

| | Value |
| -- | -- |
| Binary size (`--release=fast`, statically linked) | ~6 MB |
| Embedding model (MiniLM-L6-v2, F16 GGUF) | ~45 MB |
| Runtime dependencies | none (no Python, no Docker, no external vector DB) |
| Network calls at query time | none |

## 3. Retrieval quality (sanity)

On a 4-topic corpus (biology / coffee / algorithms / history) with paraphrased queries
that share no keywords with the stored text, top-1 retrieval is correct 7/7 — e.g.
"how do cells produce energy" → the mitochondria/ATP drawer; "brewing a good cup of
coffee" → the espresso drawer. Identical strings cosine to 1.00; paraphrases ~0.55;
unrelated topics ~0.03.

## Reproducing

```bash
zig build --release=fast

# point at a 384-dim model
export MEMXT_MODEL=$PWD/lib/minilm.gguf
export MEMXT_DB=/tmp/bench.db

./zig-out/bin/memxt init
/usr/bin/time -p ./zig-out/bin/memxt mine ./src bench     # mine a directory
/usr/bin/time -p ./zig-out/bin/memxt search "how does search ranking work"
/usr/bin/time -p ./zig-out/bin/memxt wake-up
```

For warm MCP-server latency, start `memxt mcp` and issue repeated
`tools/call → memory_search` requests over stdio; only the first pays the model-load cost.
