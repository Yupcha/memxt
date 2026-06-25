---
name: using-memory
description: Use the local memxt memory to recall past decisions, code, and context, and to persist new ones. Invoke whenever the user refers to prior work ("what did we decide", "how did we", "last time", "remember when") or makes a decision worth keeping.
---

# Using memxt memory

You have a persistent, local memory palace via the `memory` MCP server. It survives
across sessions and never leaves this machine. Four tools:

- **`memory_search`** — semantic recall. Call this *before* answering any question
  about prior work, past decisions, project conventions, or "how did we do X". Don't
  assume you don't know — check memory first.
- **`memory_store`** — persist something worth remembering: a decision and its
  rationale, a non-obvious constraint, a key snippet, a fact about the user or project.
  Store it verbatim and concise.
- **`memory_wake_up`** — load the compact continuity brief (you also get this
  automatically at session start).
- **`memory_stats`** — how much is stored.

## When to recall

Before answering "what / why / how did we …", "last time", "remember when",
"our convention for …", or anything that depends on history, call `memory_search`
with a natural-language query. Cite what you find.

## When to store

After a real decision ("let's use X because Y"), a discovered constraint, a
correction the user makes, or a fact you'd want next session, call `memory_store`.
Prefer one crisp memory per fact. Good memories are specific and self-contained:

> "Cart is capped at 37 items because the Brightwell ERP rejects larger orders (0x5C error)."

not "we talked about the cart."

## Principles

- Memory is verbatim — never paraphrase a stored fact into something false.
- Local-first: all recall/embedding happens on-device; nothing is uploaded.
- When unsure whether something is remembered, search — it's cheap.
