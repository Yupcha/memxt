# Competitor Kill Sheet — GitHub `topic:memory` (AI agent slice)

**Date:** 2026-07-12 · **updated 2026-07-18 for v0.4.0** (procedural memory, grounded anchors, budget recall, fleet, usage-learned relevance, dream daemon, MCP sampling/resources, demo + doctor)  
**Source:** [github.com/topics/memory](https://github.com/topics/memory) (7k+ repos; we filtered to **AI agent memory** products)  
**Clones:** shallow `--depth 1` under `research/competitors/`  
**Our product:** [memxt](https://github.com/Yupcha/memxt) — Zig, local MCP, coding-agent hooks  

> **Note:** Raw `topic:memory` is polluted (TiDB, memray, psutil, MemReduct, GPS timeline apps). Those are **not** competitors. This sheet is the real battlefield.

---

## Battlefield map (who is actually in the fight)

| Stars (topic page ~) | Product | Stack | Primary bet | Closest threat to memxt? |
|--|--|--|--|--|
| 73k | **Understand-Anything** | TS | Code → interactive knowledge graph for agents | High (coding KG, multi-harness) |
| 61k | **Mem0** | Py/TS | Universal memory layer + cloud, SOTA benches | High (category king) |
| 57k | **MemPalace** | Python | Local verbatim palace, Chroma, MCP, LongMemEval | **Critical** (same metaphor + local) |
| 28k | **Supermemory** | TS | Memory API + app + local + connectors | High (product + local binary) |
| 25k | **agentmemory** | TS/Node | Coding-agent memory, 53 tools, connect *, 0 DBs | **Critical** (exact ICP) |
| 18k | **Hindsight** | Python | Retain/Recall/Reflect, LongMemEval SOTA claims | Medium (accuracy brand) |
| 16k | **Memvid** | Rust | Single-file “smart frames”, sub-5ms, time travel | High (local, perf, Rust) |
| 16k | **Memori** | Py/TS | Enterprise agent-native memory, API key | Low (enterprise cloud) |
| 14k | **memU** | Python | File-native personal memory, coding workspace | Medium (files + agents) |
| 12k | **Cognee** | Python | Company brain / KG platform | Medium (institutional) |
| 11k | **EverOS** | Python | Markdown-native local OS, SQLite+LanceDB | High (local-first OS story) |
| 10k | **MemOS** | TS | Memory OS, hybrid FTS+vec, local plugins | High (OS + local plugins) |
| 8.5k | **TencentDB Agent Memory** | TS | 4-tier layering, SQLite+sqlite-vec local | **Critical** (same stack!) |
| ~20k+ | **Letta** (MemGPT) | TS | Stateful agent runtime = memory OS | Medium (agent, not library) |
| Zep OSS | **Graphiti** | Python | Temporal knowledge graph | High (temporal truth) |
| **~87k** | **claude-mem** | TS/Node | Claude Code session memory + AI compress + progressive disclosure | **Critical** (exact ICP, distribution king) |

Cloned locally:

```
research/competitors/
  agentmemory  cognee  EverOS  graphiti  hindsight  letta
  mem0  Memori  MemOS  mempalace  memU  memvid
  supermemory  TencentDB-Agent-Memory  Understand-Anything
```

---

## Core feature matrix (what they lead with)

### 1. Mem0 — category king
- **Core:** Multi-level memory (user / session / agent), fact extraction, entity linking  
- **Retrieval:** Multi-signal (semantic + BM25 + entity), temporal ranking  
- **Algo (2026):** ADD-only single-pass extract; claims LoCoMo 92.5, LongMemEval 94.4 (managed)  
- **Surface:** SDKs, managed cloud, “sign up as agent”  
- **Kill angle:** Cloud-first quality numbers; OSS ≠ platform; Python/API latency; **not coding-hook native**; needs LLM for extract  

### 2. MemPalace — our twin
- **Core:** Wing/Room/Drawer palace, **verbatim** storage, local-first  
- **Bench:** LongMemEval-style claims, R@5 raw  
- **Stack:** Python + Chroma (or sqlite_exact, milvus) + embedding model ~300MB  
- **MCP:** Yes  
- **Kill angle:** We already reimplement this in Zig **faster, smaller, no Python**. Don’t fight their benches with copy — **out-speed and out-hook them**, then beat quality with hierarchy  

### 3. agentmemory — coding-agent monster
- **Core:** Persistent memory for Claude Code, Copilot CLI, Cursor, Gemini CLI, Codex, Hermes, OpenClaw…  
- **Product UX:** `agentmemory connect <harness>`, 53 MCP tools, 12 hooks, skills pack, real-time viewer  
- **Claims:** 95.2% R@5, 92% fewer tokens, 0 external DBs  
- **Kill angle:** Node server + iii-engine pin; heavy tool surface (53 tools = cognitive load). **memxt: fewer tools, better defaults (hooks + wake-up), 6MB binary, true offline embeddings**  

### 4. Supermemory — full product
- **Core:** Fact memory + profiles + hybrid RAG + connectors + multi-modal + local server  
- **Benches:** #1 LongMemEval / LoCoMo / ConvoMem (claimed)  
- **Kill angle:** Default cloud; local is secondary. We own **always-local coding kernel**  

### 5. Graphiti / Zep — temporal graph
- **Core:** Episodes, temporal facts, valid-now vs valid-then, hybrid semantic+keyword+graph  
- **Needs:** Neo4j/Falkor/Kuzu + LLM  
- **Kill angle:** Ops heavy. Port **temporal fact model** into SQLite without Neo4j  

### 6. Hindsight — accuracy brand
- **Core:** Retain / Recall / Reflect; mental models; graph+temporal+BM25  
- **Deploy:** Docker + Postgres (+ UI)  
- **Kill angle:** Not one-binary; not Claude-hook native  

### 7. Memvid — single-file infinite
- **Core:** Append-only smart frames, time-travel queries, HNSW+ONNX, sub-5ms local  
- **Stack:** Rust core  
- **Kill angle:** Steal **append-only + as-of + single-file** narrative; we add agent hooks + palace + MCP  

### 8. EverOS — markdown memory OS
- **Core:** Trajectories as Markdown, SQLite + LanceDB indexes, local-first  
- **Kill angle:** Human-readable files good; we keep SQLite binary + optional export, faster path  

### 9. MemOS — memory OS + plugins
- **Core:** Hybrid FTS5+vector, tiered skills, multi-agent, local OpenClaw/Hermes plugins, viewer  
- **Kill angle:** Same hybrid idea we have; they have skill evolution. We need **procedures + dream**  

### 10. TencentDB Agent Memory — layered + sqlite-vec
- **Core:** L0–L3 progressive disclosure; Mermaid symbolic canvas; SQLite+sqlite-vec default  
- **Surface:** OpenClaw / Hermes plugins  
- **Kill angle:** Almost our stack. Differentiate with **Zig binary + Claude Code depth + infinite hot/cold + multi-harness adopt**  

### 11. memU — files as memory
- **Core:** INDEX.md / MEMORY.md / SKILL.md; multimodal ingest; Locomo ~92%  
- **Kill angle:** File-native is transparent; weaker semantic engine; we can **export markdown views** without being markdown-primary  

### 12. Understand-Anything — code graph
- **Core:** Repo → interactive KG for Claude/Codex/Cursor…  
- **Kill angle:** Complementary: they map **code structure**; we map **decisions + continuity**. Optional: ingest their export  

### 13. Letta — agent runtime
- **Core:** Agent *is* memory (OS metaphor), self-editing  
- **Kill angle:** Different product. We’re a **memory kernel other agents plug into**, not a full agent  

### 14. Cognee — company brain
- **Core:** Ingest anything → graph/vector, multi-tenant traits  
- **Kill angle:** Enterprise/platform. We stay **dev machine + coding agents**  

### 15. Memori — enterprise
- API-key layer, multi-framework. Not our fight.

---

## Shared industry playbook (what “everyone” ships)

| Capability | Industry default | memxt v0.4 | Notes |
|--|--|--|--|
| Hybrid search (vec + BM25/FTS) | Almost all | ✅ FTS5+RRF, 5 modes | + usage-learned relevance boost (unique) |
| MCP for coding agents | agentmemory, mempalace, supermemory, MemOS… | ✅ 10 tools + resources + annotations | `adopt` multi-harness shipped |
| Claude/Cursor hooks | agentmemory leads | ✅ Claude deep + Codex/Grok/Cursor wire | SessionStart/PreCompact/Stop |
| Fact extraction + temporal | Mem0, Graphiti, Hindsight | ✅ facts + supersession + `as_of` + contradiction flags | + opt-in client-model sampling ($0) |
| Profiles | Supermemory, Mem0 | ✅ versioned entries in wake-up | |
| Procedural memory | MemOS skills evolution | ✅ mined procedures → **emits Claude Code skills** | unique: memory writes your skills |
| Grounded / staleness | nobody | ✅ file+hash anchors, `[stale]` tags at recall | **category-unique** |
| Token-budget recall | nobody | ✅ `budget_tokens` packed briefs | **category-unique** |
| Multi-agent / fleet | weak everywhere | ✅ attributed writes, lock-retry, scratch tier | |
| Local-first | MemPalace, EverOS, Memvid, Tencent, MemOS local | ✅ strongest form | zero network at query time |
| Single binary / tiny | Rare (Memvid Rust; SM local) | ✅ **unique Zig, ~7 MB** | defend |
| Infinite / tiered memory | Memvid frames, Tencent layers, MemOS L1–L3 | ✅ hot/cold + 4-bit + **dream daemon** | sleep-time compute |
| Viewer / UI | agentmemory, Hindsight, MemOS | ✅ `inspect` + `serve` | |
| Benchmarks | Mem0/Hindsight/MemPalace war | ⚠ continuity 6/6 + scale, self-run | public LongMemEval number still open |
| Verbatim / provenance | MemPalace | ✅ + anchors as evidence | |
| Zero LLM at query | Rare | ✅ | never break this |

---

## Where memxt already wins (don’t dilute)

1. **True static local binary** (~7MB + MiniLM) — no Node/Python runtime tax  
2. **Zero network / zero API keys for memory ops** — including fact extraction (client-model sampling uses the model the user already pays for)  
3. **Claude Code real hooks** (SessionStart + PreCompact + Stop) — many only MCP  
4. **Verbatim drawers + grounded anchors** — memories carry evidence and admit staleness; nobody else does this  
5. **Sub-10ms wake-up without model load** — now daemon-precached and budget-fittable  
6. **Procedural memory that emits Claude Code skills** — the memory system writes your skills; category-unique  
7. **Fleet-ready one palace** — parallel subagents with attributed writes and a scratch tier  
8. **Same SQLite+sqlite-vec stack as Tencent — in Zig, smaller, faster cold start**  
9. **`memxt demo`** — 60-second proof on the visitor's own repo; no competitor has an instant-wow path

---

## Kill strategy: how we make each irrelevant for *our* ICP

**ICP:** Developers using **Claude Code / Codex / Grok / Cursor** who want **local** memory, not a SaaS brain.

### Positioning (one sentence)

> **memxt is the local memory kernel for coding agents: infinite history, temporal truth, one binary, every harness — nothing leaves your machine.**

Not “another Mem0.” Not “MemPalace in Zig.”  
**The libc of agent memory for people who ship code.**

### Weaponized roadmap (priority = kill list)

| Priority | Ship | Kills |
|--|--|--|
| P0 | `memxt adopt` / `connect` for Claude+Codex+Grok+Cursor | agentmemory’s install UX |
| P0 | Facts + supersession + profiles + search modes | Mem0/Supermemory “intelligence” *locally* |
| P0 | Infinite hot/cold + `dream` consolidation | Memvid/Tencent/MemOS layering |
| P1 | Temporal `as_of` + graph auto-fill | Graphiti without Neo4j |
| P1 | `inspect` + localhost UI | agentmemory viewer / MemOS dashboard |
| P1 | Coding Continuity Bench + 100k-drawer scale bench | Mem0/Hindsight narrative monopoly |
| P2 | AST-aware mine + optional Understand-Anything import | Understand-Anything overlap |
| P2 | Markdown export of palace (EverOS transparency without being Python) | EverOS/memU file story |
| Avoid | Cloud connectors, multi-tenant SaaS, 53 MCP tools | Their moats / our distractions |

### Feature parity “enough to kill” (not full clone)

| Competitor feature | memxt minimum lethal dose |
|--|--|
| Mem0 multi-signal + temporal | Hybrid + facts + as_of |
| agentmemory 53 tools | **5–8 sharp tools** + auto hooks |
| MemPalace palace | Already have; beat on speed + incremental mine |
| Supermemory profile ~50ms | `memory_profile` no-model |
| Graphiti temporal KG | facts.valid_until + simple edges |
| Memvid time travel | as_of + content-addressed history |
| Tencent L0–L3 | working/episodic/semantic/procedural + tiers |
| MemOS skills evolution | procedural drawers + dream promote |

### Narrative attacks (marketing)

| Their claim | Our counter-claim |
|--|--|
| “SOTA LongMemEval” | “SOTA **coding continuity** offline; 0 API $; 10ms wake-up” |
| “53 tools” | “5 tools the agent actually uses + hooks so it doesn’t forget to” |
| “Managed memory” | “No account. Your palace. Audit with `export`.” |
| “Python/Node local” | “6MB binary. No venv. No node_modules.” |
| “Company brain” | “Repo brain. Decisions that survive compact.” |

---

## Competitive gaps we must close (honest — post-v0.4)

Closed since 2026-07-12: fact lifecycle + contradictions ✅ · multi-harness adopt ✅ · tiering + dream (now a daemon) ✅ · monitor UI ✅ · procedural memory ✅ · staleness/grounding ✅ · fleet concurrency ✅.

Still open:

| Gap | Severity | Plan |
|--|--|--|
| Stars / distribution / social proof | **Critical** | v0.4.0 release + brew tap + Show HN + plugin marketplace ranking |
| No public benchmark number (LongMemEval-class) | High | run a public subset locally, publish score + harness |
| No Windows support | High | Zig makes it feasible; biggest unreached audience |
| Real-world burn-in on v0.4 features | High | 1–2 weeks dogfooding before launch push |
| Knowledge-graph auto edges | Medium | NER on mine (roadmap v0.6) |
| No AST code intelligence | Medium | P2; Understand-Anything stays complementary |
| No team/network effect | Medium | federated palace sync (roadmap v0.6) — the growth unlock |

---

## Stack comparison (engineering truth)

| | memxt | MemPalace | agentmemory | Mem0 | Memvid | TencentDB AM |
|--|--|--|--|--|--|--|
| Language | Zig | Python | TS | Python | Rust | TS |
| Runtime deps | none | Python+ML | Node+iii | Python/cloud | none (core) | Node |
| Embeddings | llama.cpp on-device | local model | local/server | often API | ONNX local | local vec |
| Store | SQLite+vec+FTS | Chroma/SQLite | engine DB | Qdrant/etc | single file | SQLite+vec |
| Coding hooks | Claude deep | MCP | many harnesses | weak | weak | OpenClaw/Hermes |
| Footprint | ~7MB+45MB model | ~300MB+ model | Node heavy | heavy | small | Node |

**Engineering thesis:** Only **Memvid** and **memxt** are native-binary local. Memvid wins storage inventiveness; **memxt wins agent loop**. Combine Memvid-class infinite store + agentmemory-class harness UX + Graphiti-class temporal facts = kill zone.

---

## Battle order

**Days 1–90 of the original plan: executed.** adopt/instructions, facts+supersession+profiles, hot/cold+dream, search modes+as_of, serve UI, continuity+scale benches — all shipped, plus the v0.4 wave (procedures, anchors, budget recall, fleet, telemetry, dream daemon, sampling, demo, doctor).

### Next 90 days — distribution, not features
1. **Stabilize** — dogfood v0.4 daily; fix what `doctor` and real use surface  
2. **Release** — v0.4.0 tag + binaries + brew tap live  
3. **Credibility** — one public benchmark number + 3–5 quotable early users  
4. **Launch week** — Show HN (draft ready in `docs/launch/show-hn.md`) + Claude Code Discord/subreddit + X, same week; topic tags `ai-memory`, `agent-memory`, `mcp`  
5. **Windows** — the biggest unreached audience  
6. **Team sync** — federated palaces; the only feature that adds a network effect  

---

## Grok / multi-subscription (local tool reminder)

All of these competitors that matter for coding either:

- run a **local MCP/server**, or  
- push you to **cloud**

**memxt stays local MCP** for Claude Code, Codex CLI, Grok CLI:

```toml
# ~/.grok/config.toml  AND  ~/.codex/config.toml  (same idea)
[mcp_servers.memory]
command = "/Users/YOU/.memxt/bin/memxt"
args = ["mcp"]
env = { MEMXT_DB = "/Users/YOU/.memxt/palace.db", MEMXT_MODEL = "/Users/YOU/.memxt/lib/minilm.gguf" }
```

Shared `MEMXT_DB` = one brain across every subscription’s CLI.

---

## Bottom line

| Don’t try to | Do |
|--|--|
| Out-Mem0 Mem0 on cloud LoCoMo with a team of 1 | Own **local coding continuity** |
| Ship 53 MCP tools | Ship **auto hooks + 6 perfect tools** |
| Clone Neo4j Graphiti | Ship **temporal facts in SQLite** |
| Match every connector | Match **every coding harness** |
| Be a company brain SaaS | Be **the binary on the machine** |

**The kill shot:**  
`curl | bash` → `memxt demo` (60-second proof: paraphrase recall on their own repo) → `memxt adopt --write` → open Claude/Codex/Grok → agent already knows the repo, never re-breaks last week’s decision, flags stale memories, learns the team’s procedures into skills, works offline, fits in a static binary, consolidates itself overnight.

Clones are in `research/competitors/`. Machine-readable parse: `research/competitors_summary.json`.
