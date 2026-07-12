---
name: using-memory
description: Use the local memxt memory to recall past decisions, code, and context, and to persist new ones. Invoke whenever the user refers to prior work ("what did we decide", "how did we", "last time", "remember when") or makes a decision worth keeping.
---

# Using memxt memory

You have a persistent, **local** memory palace via the `memory` MCP server.
It survives across sessions. Nothing leaves this machine. No cloud LLM is used
to compress or store memory (unlike claude-mem-style pipelines).

## Progressive disclosure (save tokens)

Always prefer this 2-step flow:

1. **`memory_search`** — default `detail=index` returns compact hits
   (`#id`, wing/room, source, ~100-char snippet). Cheap.
2. **`memory_get`** — pass promising `id` or `ids` to load **full verbatim**
   bodies only for what you need.

Do **not** pass `detail=full` unless the query is tiny or you already know you
need every body (wastes context).

Example:

```
memory_search({ query: "cart limit", limit: 5 })
→ #42 decisions/… "Cart is capped at 37…"
memory_get({ ids: [42] })
→ full drawer text
```

## Other tools

- **`memory_wake_up`** — continuity brief (also auto-injected at SessionStart).
- **`memory_profile`** — stable project facts; no embedding model.
- **`memory_store`** — persist a decision / constraint / fact (verbatim).
  Prefer `room: "decisions"` for architecture choices.
- **`memory_forget`** — delete by drawer id.
- **`memory_stats`** / **`memory_dream`** — health / consolidation.

## When to recall

Before answering "what / why / how did we …", "last time", "remember when",
"our convention for …", or anything that depends on history:

1. `memory_search` (index)
2. `memory_get` on relevant ids
3. Cite `#id` / source when you use a memory

## When to store

After a real decision ("let's use X because Y"), a discovered constraint, a
correction the user makes, or a fact you'd want next session, call
`memory_store`. One crisp memory per fact.

Good:

> "Cart is capped at 37 items because the Brightwell ERP rejects larger orders (0x5C error)."

Bad: "we talked about the cart."

**Hooks already autosave** session tails on Stop + PreCompact (local, verbatim).
Still call `memory_store` for **important decisions** so they land in the
profile, not only as a long episode.

## Principles

- Memory is **verbatim** — never invent from a fuzzy summary.
- **Local-first**: embeddings + search on-device; zero network at query time.
- When unsure, **search** — index is cheap; full get is on demand.
