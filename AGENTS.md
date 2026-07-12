# Agent instructions (memxt)

## Memory (memxt)

You have a persistent, **local** memory palace via the `memory` MCP server.
Nothing leaves this machine. Shared across Claude Code / Codex / Cursor / Grok CLI.
No cloud LLM is used to compress memory.

### Progressive disclosure (default)

1. `memory_search` — **index** by default (compact `#id` + snippet)
2. `memory_get` — full verbatim body for promising `id` / `ids` only
3. Prefer `detail: "full"` only when you need every body immediately

### Tools
- `memory_wake_up` — call at the **start of every session** (Grok does not auto-inject)
- `memory_profile` — stable project facts (fast, no embedding model)
- `memory_search` — before answering about prior work; modes: `hybrid` | `memories` | `documents` | `facts` | `episodes`
- `memory_get` — expand index hits by drawer id
- `memory_store` — after a real decision; prefer `room: "decisions"`
- `memory_forget` — remove wrong/stale memories by id
- `memory_dream` — optional consolidation (hot budget + 4-bit quant)
- `memory_stats` — health

### Rules
1. At session start: `memory_wake_up` then continue.
2. Before "what did we decide / how does X work here": `memory_search` → `memory_get`.
3. After a real decision or user correction: `memory_store` one crisp fact.
4. Default wing for this repo is `memxt` (or git-derived).
5. Claude Code hooks also autosave session tails (Stop + PreCompact) locally — still store decisions explicitly.
