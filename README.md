<div align="center">
  <img src="assets/logo.svg" alt="memxt" width="280"/>

  <h1>memxt</h1>

  <p>
    <b>Your coding agent forgets everything. Fix that — locally.</b><br/>
    Long-term memory for <b>Claude Code</b>, Codex, Cursor, Grok CLI, and any MCP client.<br/>
    No cloud. No memory API key. Nothing leaves your machine.
  </p>

  <p>
    <a href="https://github.com/Yupcha/memxt/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT"/></a>
    <a href="#-install"><img src="https://img.shields.io/badge/install-curl%20%7C%20bash-black?style=flat-square" alt="install"/></a>
    <a href="#-proof-not-vibes"><img src="https://img.shields.io/badge/continuity-6%2F6-brightgreen?style=flat-square" alt="continuity"/></a>
    <a href="#-token-savings-real-measurement"><img src="https://img.shields.io/badge/tokens-72%25%20less-orange?style=flat-square" alt="tokens"/></a>
    <a href="#-proof-not-vibes"><img src="https://img.shields.io/badge/wake--up-10ms-purple?style=flat-square" alt="wake"/></a>
    <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey?style=flat-square" alt="platform"/>
  </p>

  <img src="assets/demo.gif" alt="memxt demo" width="720"/>

  <p>
    <a href="#-install"><b>Install</b></a> ·
    <a href="#-30-seconds-with-claude-code"><b>Claude Code</b></a> ·
    <a href="#-every-coding-agent"><b>All agents</b></a> ·
    <a href="#-token-savings-real-measurement"><b>Token proof</b></a> ·
    <a href="#vs-the-alternatives"><b>vs claude-mem / Mem0</b></a> ·
    <a href="./docs/harnesses.md"><b>Docs</b></a>
  </p>
</div>

---

## The problem

You already pay for Claude / Codex / Grok. Every session still starts **amnesiac**:

- You re-explain architecture and “why we rejected X”
- Compaction eats the decision you made an hour ago  
- Next session undoes the cart cap, reintroduces Redis, reopens the debate  

Cloud “memory layers” fix amnesia by **uploading your codebase and chat**. That’s a non-starter for real work.

**memxt** is the other path: a **local memory palace** your agent searches and writes — wired into the coding loop with MCP + Claude hooks.

---

## Why people star this

| | Without memxt | With memxt |
|--|--|--|
| New session | Paste README / re-Read half the repo | **`memory_wake_up` ~10 ms** |
| “What did we decide?” | Guess or dig through files | **`memory_search` → `memory_get`** (index first) |
| After compact / end of turn | Context gone | **PreCompact + Stop** autosave (verbatim, local) |
| Privacy | Cloud memory API / LLM compress | **100% on-device · no memory LLM** |
| Tokens (this repo, measured) | **9,623** doc dump | **2,703** wake + 5 searches → **72% less** |

```
docs dump every restart     ████████████████████████████  9.6k tokens
memxt wake + targeted recall ████████                      2.7k tokens
```

---

## ⚡ Install

```bash
curl -fsSL https://raw.githubusercontent.com/Yupcha/memxt/main/install.sh | bash
```

→ `~/.memxt/bin/memxt` + on-device MiniLM model. **macOS / Linux**, x86_64 & arm64.

```bash
~/.memxt/bin/memxt adopt --write   # mine cwd + wire Cursor/Codex/Grok snippets
~/.memxt/bin/memxt inspect         # palace health
~/.memxt/bin/memxt serve           # UI → http://127.0.0.1:8765
```

---

## 30 seconds with Claude Code

```text
/plugin marketplace add Yupcha/memxt
/plugin install memxt
```

| You get | What it does |
|--|--|
| **SessionStart** | Auto-injects continuity brief every session |
| **PreCompact** | Saves the conversation *before* context is crushed |
| **Stop** | Autosaves the turn tail (verbatim, local embed — no cloud LLM) |
| **`memory_search` → `memory_get`** | Progressive disclosure: cheap index, full body on demand |
| **`memory_store` / `wake_up` / `profile`** | Persist + continuity tools |
| **`/remember` · `/recall`** | Explicit slash commands |

```bash
~/.memxt/bin/memxt mine . my-project   # optional: seed from the repo
```

Next session: no re-explaining the **37-item cart cap**, the **SQLite choice**, or the **Redis ban**.

---

## Every coding agent

**One palace. Every subscription.** Same `MEMXT_DB` for Claude, Codex, Cursor, Grok.

| Agent | Setup |
|--|--|
| **Claude Code** | Plugin (above) — best experience |
| **Codex** | `memxt instructions --harness codex` → `config.toml` + `AGENTS.md` |
| **Cursor** | `memxt adopt --write` → `.cursor/mcp.json` |
| **Grok CLI** | `grok mcp add memory -e MEMXT_DB=… -e MEMXT_MODEL=… -- ~/.memxt/bin/memxt mcp` then **restart** |
| **Any MCP client** | `memxt mcp` over stdio |

```bash
~/.memxt/bin/memxt instructions --harness grok   # also: codex | cursor | zed | claude
```

Standing rules live in [`AGENTS.md`](./AGENTS.md) so agents **know when** to call tools.  
Full Grok checklist (doctor, restart, troubleshooting) → [docs/harnesses.md](./docs/harnesses.md) · [Grok section in docs](./docs/harnesses.md#grok-cli-grok-build).

> MCP loads at **session start**. After `grok mcp add`, open a **new** Grok session.

---

## Proof, not vibes

### Coding Continuity Bench — **6/6**

```bash
./scripts/bench-continuity.sh
```

Paraphrased questions (cart **37** / **0x5C**, SQLite vs Postgres, Redis ban, HttpOnly cookies) + wake-up + profile. Details → [`docs/BENCHMARKS_CONTINUITY.md`](./docs/BENCHMARKS_CONTINUITY.md).

### Latency (Apple Silicon · Metal)

| Op | Time |
|--|--|
| Session **wake-up** | **~10 ms** (no model load) |
| Warm vector search (MCP resident) | **sub-ms** |
| Mine ~15 files | **~1 s** (real MiniLM) |
| Peak RAM (model loaded) | **~100 MB** |

Method → [`BENCHMARK.md`](./BENCHMARK.md).

### Scale + compression

```bash
N=500 HOT_BUDGET=100 ./scripts/bench-scale.sh
```

`dream` caps hot f32 vectors and keeps cold history as **4-bit TurboQuant-style** embeddings (~6× smaller) + FTS — infinite history without infinite RAM.

---

## Token savings (real measurement)

Not a synthetic leaderboard. On **this** repo we:

1. Wired Grok to `~/.memxt/palace.db`  
2. Mined the project + stored the actual decisions from that work  
3. Asked the agent to answer **5 continuity questions**  

| Path | Context into the model | Tokens\* |
|--|--|--:|
| **Without** | Paste README + ROADMAP + AGENTS + docs + recap | **9,623** |
| **With** | `wake_up` (1,281) + 5× `memory_search` limit 3 (1,422) | **2,703** |

| | |
|--|--:|
| **Saved** | **6,920 tokens (71.9%)** |
| **Ratio** | **~3.6× less** |

\* `tiktoken` cl100k_base (ratio-focused; Grok tokenizer is close enough).

**Honest caveats:** a 176-token hand-written recap can look “cheaper” — but only if you already wrote a perfect summary. Real amnesiac sessions re-dump docs or fail. Full method → [`docs/TOKEN_SAVINGS.md`](./docs/TOKEN_SAVINGS.md).

---

## How it works

```
Wings (project) → Rooms (topic) → Drawers (verbatim + embedding)
                                      ↓
                    hybrid: vectors + FTS5 + facts + recency
                                      ↓
              wake-up: identity + profile + recent work (~ms)
```

| Property | Detail |
|--|--|
| **Verbatim** | Decisions aren’t silently rewritten by an LLM |
| **Hybrid search** | Semantic + keyword (`0x5C`, function names) + fact modes |
| **Profiles** | Stable project facts; supersession when truth changes |
| **Dream** | Hot budget, cold quant, clusters — history stays, cost stays bounded |
| **Local** | MiniLM on-device + SQLite; zero network at query time |

```bash
memxt serve --port 8765          # inspect / search / dream in the browser
memxt search "cart limit" --mode hybrid
memxt search "SQLite" --mode facts --wing my-project
memxt dream --budget 50000
```

---

## vs the alternatives

We’re not trying to win cloud LoCoMo / LongMemEval leaderboards.  
We win **coding continuity, privacy, and session tokens** on your laptop.

### Head-to-head (local coding agents)

| | **memxt** | [claude-mem](https://github.com/thedotmack/claude-mem) | [Mem0](https://github.com/mem0ai/mem0) | [Supermemory](https://github.com/supermemoryai/supermemory) | [Zep / Graphiti](https://github.com/getzep/graphiti) | [MemPalace](https://github.com/MemPalace/mempalace) | [agentmemory](https://github.com/rohitg00/agentmemory) |
|--|--|--|--|--|--|--|--|
| **Default deploy** | Local binary | Claude plugin + Bun worker | Cloud (+ OSS self-host) | Cloud API (+ local) | Cloud Zep / Neo4j + LLM | Local Python | Local Node server |
| **Data leaves machine** | **Never** | Local DB; **compress uses AI providers** | Yes on managed | Yes by default | Graph stack heavy | No | No |
| **Runtime** | **~7MB Zig + MiniLM** | Node + Bun + optional Chroma | Python / cloud | Node / cloud | Python + graph DB | Python + Chroma | Node + engine |
| **Network at query / compress** | **None** | LLM SDK for observation compression | Often API | Often API | Graph + LLM | Local | Local |
| **Coding-agent hooks** | **SessionStart + PreCompact + Stop** | Deep Claude lifecycle + PostToolUse stream | Plugin → remote MCP | Product | App/SDK | MCP | Many harnesses |
| **Multi-harness** | **One palace · Claude/Codex/Cursor/Grok** | Claude-first (+ OpenClaw etc.) | Platform | Product-first | SDK | MCP | `connect *` |
| **Memory model** | **Verbatim** drawers + facts + profiles | AI-compressed observations + summaries | Extract + entities | Facts + profiles | Temporal KG | Palace metaphor | Episodes + tools |
| **Search UX** | **Index → `memory_get` (progressive)** | search → timeline → get_observations | Multi-signal | Hybrid RAG | Graph + semantic | Embeddings | Local engine |
| **Infinite / cost bound** | **`dream` + 4-bit cold** | Growing local store | Platform | Product tiers | Graph scale | Grows | Grows |
| **Wake-up** | **~10 ms** (no model) | Context inject from worker | Network | Network | Graph | Model | Server |
| **Best for** | **Private multi-agent kernel** | Claude Code autopilot product | Universal API + benches | Full memory product | Temporal entity truth | Python palace | Max harness surface |

### When to pick what

| You want… | Pick |
|--|--|
| Claude/Codex/Grok **forget less**, nothing leaves the laptop, **no memory LLM bill**, one binary | **memxt** |
| Claude Code install-and-forget, max autopilot, progressive disclosure at scale | **claude-mem** |
| Managed memory API, SDKs, published LoCoMo/LongMemEval numbers | **Mem0** |
| Polished memory product, connectors, multi-modal cloud brain | **Supermemory** |
| Temporal “what was true when” over entities at company scale | **Zep / Graphiti** |
| Python palace metaphor, experiment in notebooks | **MemPalace** |
| 50+ MCP tools and every harness CLI under the sun | **agentmemory** |
| Full agent *runtime* that *is* the memory OS | **Letta** (different product) |

### vs claude-mem (the real Claude Code peer)

[claude-mem](https://github.com/thedotmack/claude-mem) is excellent at **automatic Claude session capture**. We want those users who hit its costs or limits:

| claude-mem | memxt |
|--|--|
| Compresses tool traffic with **Claude/Gemini/OpenRouter** | **Verbatim** store + **local MiniLM** only |
| Node + Bun **worker service** always on | **Single binary** MCP / hooks |
| Claude-first product surface | **One palace** across every coding subscription |
| Progressive disclosure (index → expand) | **Same pattern**: `memory_search` → `memory_get` |
| PostToolUse firehose + AI summary | Stop/PreCompact tails + explicit `memory_store` for decisions |

**Switch pitch:** *Same continuity job. Zero cloud memory tax. Works with Grok and Codex too.*

### Honest deltas

| They lead with | memxt’s answer |
|--|--|
| claude-mem: 80k+★ Claude autopilot | **Local kernel** + multi-harness + no compress LLM — steal users who want that trade |
| Mem0 / Supermemory: cloud SOTA benches | We publish **coding continuity (6/6)** + **token savings (72%)** on real agent work |
| Graphiti: temporal KG + Neo4j | **Facts + supersession + profiles** in SQLite — no graph cluster |
| agentmemory: 53 tools | **~8 sharp tools** + hooks so the agent doesn’t forget to use them |
| MemPalace: same palace idea | **Zig binary, FTS+vec, dream compression, Claude hooks** |
| “Just paste the README” | **Wake-up + index search** beats a 9k-token dump ([measured](#-token-savings-real-measurement)) |

```
Cloud memory API     ──►  your code + chat leave the building
memxt                ──►  SQLite palace on disk · 0 API keys · 0 query network
```

Full research notes (feature kill-sheet, stack matrix) → [`research/COMPETITOR_KILL_SHEET.md`](./research/COMPETITOR_KILL_SHEET.md).

---

## CLI

```text
memxt adopt [--write] [--no-mine]    Wire agents + optional mine
memxt mine <path> [wing]             Incremental codebase ingest
memxt search <q> --mode hybrid|memories|documents|facts|episodes
memxt wake-up | inspect | dream | serve
memxt forget | export | import | mcp | hook
```

```bash
MEMXT_DB=~/.memxt/palace.db
MEMXT_MODEL=~/.memxt/lib/minilm.gguf
MEMXT_WING=my-project    # optional; else git-root name
```

---

## Build from source

Most users never need this. Requires **Zig 0.16** + cmake:

```bash
git clone --recursive https://github.com/Yupcha/memxt && cd memxt
# build llama.cpp (Metal on macOS), fetch MiniLM GGUF, then:
zig build --release=fast
```

Details in the install script and comments under `build.zig`.

---

## Roadmap · License · Star

- Roadmap → [`ROADMAP.md`](./ROADMAP.md)  
- Launch notes → [`docs/launch/`](./docs/launch/)  
- **MIT** → [`LICENSE`](./LICENSE)

If memxt saves you one re-explain session, **star the repo** and tell another Claude Code user. That’s how local tools win.
