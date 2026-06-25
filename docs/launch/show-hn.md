# Your AI coding agent forgets everything. I gave it a memory — in a single Zig binary.

*Draft launch post for HN / r/LocalLLaMA / r/mcp. Builder voice, reproducible numbers, no superlatives.*

---

Every Claude Code session starts amnesiac. I re-explain the architecture, re-state why
we chose SQLite over Postgres, and the agent still contradicts a decision we made last
week. The fix everyone reaches for — a cloud "memory layer" — means shipping my
proprietary code to someone else's server and paying per token to remember my own work.

So I built **fast-mempalace**: a persistent, **local-first** memory for AI coding agents.
It's one static binary. No Python, no Docker, no vector database to run, no API key, and
no network call at query time. Your code and your memories never leave the machine.

```bash
curl -fsSL https://raw.githubusercontent.com/debpalash/fast-mempalace/main/install.sh | bash
```

Then, in Claude Code:

```
/plugin marketplace add debpalash/fast-mempalace
/plugin install fast-mempalace
```

That's the whole setup. The agent now gets four memory tools over MCP
(`memory_search`, `memory_store`, `memory_wake_up`, `memory_stats`), a wake-up brief
injected at the start of every session, and an auto-save of the conversation right
before it gets compacted away.

## Does it actually work?

Here's the test I trust. I mined a small repo into memory, then asked Claude Code a
question whose answer exists **only** in that code — with the file, search, and web
tools *disabled*, so the only way to answer is to recall it:

```
$ claude -p "What is the max number of items in the ShopFast cart, and why?" \
    --disallowedTools "Read,Bash,Grep,Glob"
ShopFast caps the cart at 37 items because the Brightwell ERP rejects larger
orders with a 0x5C error, so it's enforced client-side as a guard.
```

It pulled "37 items / Brightwell ERP / 0x5C" straight from `memory_search`. On a
4-topic paraphrase test (queries that share no keywords with the stored text), top-1
retrieval is 7/7.

## Why a single binary matters

Almost every agent-memory tool today is a Python or Node package sitting on top of a
vector DB (Chroma, pgvector, Pinecone) or a managed cloud service. That's a dependency
tree, a service to run, and — for the cloud ones — your data on someone else's box.

fast-mempalace is `llama.cpp` + `sqlite-vec` statically linked into one ~6 MB
executable. Embeddings (MiniLM-L6-v2, 384-dim) run on-device via Metal/CUDA. Storage is
one SQLite file. There's nothing to stand up and nothing to phone home. Memories are
stored **verbatim** — never silently rewritten or summarized by an LLM — which also
means there's no graph-query surface to poison.

## Numbers (Apple Silicon, Metal, honest)

| Operation | Time | Notes |
|--|--|--|
| Cold start / session wake-up | **0.01 s** | no model load — runs every session |
| Mine 15 files → 31 drawers | **~1.0 s** | real on-device embeddings |
| Vector search (warm MCP server) | **sub-ms** | model loaded once, stays resident |
| Binary size | **~6 MB** | statically linked, zero runtime deps |
| Peak RAM (model loaded) | **~100 MB** | mostly the embedding model |

Full method + a one-command reproduction is in
[`BENCHMARK.md`](https://github.com/debpalash/fast-mempalace/blob/main/BENCHMARK.md).
(I'll be upfront: an earlier version of this repo reported a `0.59 s` mine of 1,171
drawers — that run used placeholder vectors. These are the real semantic engine.)

## What it isn't

It's not a cloud service, not an LLM, and not trying to replace your model — it's the
memory substrate that feeds whatever model you already use. It's early (v0.2). The
knowledge graph is there but populated manually for now. I'd love feedback on retrieval
quality and on the hook UX.

MIT licensed. Code, plugin, and reproduction:
**https://github.com/debpalash/fast-mempalace**

---

### Title options
- `Show HN: fast-mempalace – local-first memory for AI agents in a single Zig binary (no vector DB)`
- `Show HN: I gave Claude Code a persistent memory that never leaves my machine`
- *(r/LocalLLaMA)* `Local-first memory for coding agents: llama.cpp + sqlite-vec in one static binary, no cloud`
