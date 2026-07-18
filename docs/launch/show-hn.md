# Show HN: memxt – local memory for Claude Code (and every coding agent)

*Ready to paste. Builder voice, continuity-first. Updated for v0.4.*

---

**Title:** Show HN: memxt – local long-term memory for Claude Code (no cloud)

**Text:**

Every Claude Code session starts amnesiac. I re-explain architecture, re-state why we chose SQLite, and after compact the agent still undoes last week's decision.

Cloud memory layers (and many "local" plugins) fix amnesia by shipping chat to a memory API or by running an extra LLM to compress every tool call. I wanted a **coding-agent memory kernel**: MCP tools, real hooks, one local SQLite palace shared with Codex / Cursor / Grok CLI — **nothing leaves the machine, no memory LLM bill**.

So I built **memxt**. See it work in 60 seconds:

```bash
curl -fsSL https://raw.githubusercontent.com/Yupcha/memxt/main/install.sh | bash
~/.memxt/bin/memxt demo
```

The demo stores three decisions, starts a "new session," and recalls each one from a *paraphrased* question ("maximum items in one basket" → the cart-cap decision) — then live-mines your repo and shows the token math. Throwaway palace, nothing persisted.

In Claude Code:

```
/plugin marketplace add Yupcha/memxt
/plugin install memxt
```

### What you get

- **SessionStart** injects a continuity brief (~10 ms, no model load); **PreCompact + Stop** autosave the tail (verbatim + on-device MiniLM — **not** cloud compression)
- **Hybrid recall** — vectors + FTS5 (exact identifiers like `0x5C`) + facts, with progressive disclosure (`memory_search` index → `memory_get`)
- **Grounded memory** — memories anchor to file + content hash; recall tags `[stale]` when the code they cite has changed since
- **Procedural memory** — repeated successful workflows become procedures; `memxt skills --emit` writes them out as Claude Code skills
- **Token-budget recall** — ask for the best brief that fits N tokens
- **Fleet-ready** — parallel subagents share one palace: attributed writes, lock-retry, a scratch tier that expires unless promoted
- **Sleep-time compute** — `memxt dream --daemon` consolidates in the background: 4-bit cold vectors, near-dup merges, contradiction flags, pre-rendered wake briefs
- Fully **local**: one ~7 MB binary, SQLite, zero memory API key

### vs the big Claude memory plugin

[claude-mem](https://github.com/thedotmack/claude-mem) is excellent Claude Code autopilot. memxt is the other bet: **same continuity job**, multi-agent one palace, **no cloud LLM in the memory loop**.

### Does continuity actually work?

```bash
./scripts/bench-continuity.sh
# SCORE 6/6 — paraphrase recall of cart-cap / SQLite / Redis ban / auth cookies
```

Token savings on this repo (real agent path, not a synthetic leaderboard): ~9.6k tokens of doc-dump without, ~2.7k with wake + targeted search → **~72% less**. Method: `docs/TOKEN_SAVINGS.md`.

### What it isn't

Not a cloud SaaS, not "#1 LongMemEval," not a full agent runtime. It's the **local memory kernel for coding agents** so Claude Code (and friends) stop starting from zero.

Repo: https://github.com/Yupcha/memxt
MIT. Feedback welcome — especially if you live in Claude Code daily.

---

## First comment (post immediately after submitting)

How it works, for the curious:

The palace is one SQLite file: wings (projects) → rooms (topics) → drawers (verbatim text + a 384-dim MiniLM embedding, computed on-device via llama.cpp — Metal on macOS). Search fuses sqlite-vec KNN, FTS5 BM25 (RRF), extracted facts, recency, and a learned boost from which results the agent actually opens. Wake-up doesn't touch the model at all — it's a SQL assembly of identity + project profile + recent work, which is why it's ~10 ms.

Facts get extracted heuristically at store time (subject/predicate/object with supersession, so "we use Postgres" → "we use SQLite" resolves). Optionally, if your MCP client supports sampling, memxt asks *the client's own model* to extract richer facts — still zero API keys, the model you already pay for.

Zig 0.16, ~7 MB static binary, MIT. Happy to answer anything about the retrieval fusion, the 4-bit cold-vector quantization, or the Claude Code hook protocol.
