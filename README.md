<div align="center">
  <img src="assets/logo.svg" alt="memXT" width="380"/>

  <p>
    <b>Local long-term memory for coding agents</b> — Claude Code, Codex, Cursor, Grok CLI.<br/>
    Your agent stops forgetting. Your code never leaves your machine.
  </p>

  <p>
    <a href="https://github.com/Yupcha/memxt/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT"/></a>
    <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey?style=flat-square" alt="platform"/>
    <img src="https://img.shields.io/badge/memory%20bill-%240%20·%20no%20API%20keys-brightgreen?style=flat-square" alt="$0"/>
  </p>

  <img src="assets/demo-tour.gif" alt="memxt demo — recalls decisions from paraphrased questions" width="720"/>
</div>

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Yupcha/memxt/main/install.sh | bash
```

```bash
~/.memxt/bin/memxt demo     # 60-second tour on a throwaway palace (the GIF above)
~/.memxt/bin/memxt adopt --write   # wire your agents + mine this repo
~/.memxt/bin/memxt doctor   # if anything's off — every ✗ prints its fix command
```

macOS / Linux, x86_64 & arm64. One ~7 MB binary + an on-device MiniLM model. No accounts, no keys, zero network at query time.

## Claude Code

```text
/plugin marketplace add Yupcha/memxt
/plugin install memxt
```

Done. Every session now wakes up with project decisions and recent work (~10 ms), auto-saves before compaction and on stop, and recalls via `memory_search` → `memory_get`. `/remember` and `/recall` when you want to be explicit.

## Other agents — one shared palace

| Agent | Setup |
|--|--|
| **Codex** | `memxt instructions --harness codex` |
| **Cursor** | `memxt adopt --write` → `.cursor/mcp.json` |
| **Grok CLI** | `grok mcp add memory … -- ~/.memxt/bin/memxt mcp` |
| **Any MCP client** | `memxt mcp` over stdio |

All of them read and write the same `MEMXT_DB`. Open a new session after wiring. Full guide → [`docs/harnesses.md`](./docs/harnesses.md).

## How it works

```
   Wings (projects) → Rooms (topics) → Drawers (verbatim memory + embedding)
                              │
          search  =  vectors + FTS5 + facts + recency, fused
          wake-up =  identity + project truth + recent work, ~10 ms
```

Memories are kept **verbatim** (no LLM rewriting), searched **hybrid** (semantic + exact keywords like `0x5C`), and consolidated by **dream**: hot vectors stay f32, cold history compresses to 4-bit, stale facts expire.

**Numbers** (Apple Silicon, method in [`BENCHMARK.md`](./BENCHMARK.md)): wake-up ~10 ms · warm search sub-ms · ~100 MB peak RAM · continuity bench 6/6 · **72% fewer tokens** than re-pasting docs each session ([method](./docs/TOKEN_SAVINGS.md)).

## Built for agents (v0.4)

- **Procedural memory** — repeated successful workflows become procedures; `memxt skills --emit` turns them into Claude Code skills.
- **Grounded memory** — memories anchor to file + content hash; recall tags `[stale]` when the evidence changed.
- **Token-budget recall** — `budget_tokens` on search/wake-up returns the best brief that fits.
- **Fleet-ready** — parallel subagents share one palace: attributed writes, lock-retry, scratch tier with `memory_promote`.
- **Usage-learned relevance** — memories the agent actually opens rank higher; ignored ones decay.
- **Sleep-time compute** — `memxt dream --daemon` consolidates in the background and flags contradicting facts.
- **Client-model sampling** — opt-in (`MEMXT_SAMPLING=1`): fact extraction by your client's own model, still $0.

## vs the alternatives

We studied 15 agent-memory products ([full teardown](./research/COMPETITOR_KILL_SHEET.md)). The field splits into cloud memory APIs (Mem0, Supermemory), Python/Node local layers (MemPalace, agentmemory, MemOS), and Claude-first plugins (claude-mem). memxt's bet: **the only native-binary, $0-memory-loop option that's deep in every coding harness.**

| | **memxt** | claude-mem | Mem0 / Supermemory |
|--|--|--|--|
| Code leaves machine | **never** | compresses via cloud LLM | yes, by default |
| Memory LLM bill | **$0** | metered | metered |
| Works with | Claude · Codex · Cursor · Grok | Claude-first | platform |
| Remembers | **verbatim** + facts + anchors | AI summaries | extracted entities |

Nobody else has: grounded memories that admit they're `[stale]`, procedural memory that emits agent skills, token-budget recall, or a 60-second `demo` you can verify on your own repo.

## CLI

```text
memxt demo [--keep]                  60-second tour on a throwaway palace
memxt doctor                         Self-diagnosis with exact fix commands
memxt adopt [--write] [--no-mine]    Wire up agents + optionally mine the repo
memxt mine <path> [wing]             Incremental codebase ingest
memxt search <q> --mode hybrid | memories | documents | facts | episodes
memxt wake-up [--budget N] | inspect | dream | serve
memxt dream --daemon | --status | --contradictions
memxt skills [--emit [dir]]          Procedural memory → Claude Code skills
memxt anchors [--verify]             Grounded-memory anchor health
memxt forget | export | import | mcp | hook | instructions
```

```bash
MEMXT_DB=~/.memxt/palace.db      MEMXT_MODEL=~/.memxt/lib/minilm.gguf
MEMXT_WING=my-project            # optional; defaults to the git-root name
```

## Build from source

Zig 0.16 + cmake:

```bash
git clone --recursive https://github.com/Yupcha/memxt && cd memxt && zig build --release=fast
```

---

<div align="center">

[`ROADMAP.md`](./ROADMAP.md) · [MIT](./LICENSE) · <a href="https://yupcha.github.io/memxt/assets/logo-3d.html">3D logo</a>

**If memxt saves you one re-explain session, [star it](https://github.com/Yupcha/memxt).**

</div>
