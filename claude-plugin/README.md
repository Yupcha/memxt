# memxt — Claude Code plugin

Gives Claude Code a persistent, **local-first** memory. Your agent remembers your
codebase, your decisions, and your conventions across sessions — and nothing ever
leaves your machine.

## What it adds

- **MCP server `memory`** with progressive disclosure:
  `memory_search` (index by default) → `memory_get` (full body by id),
  plus `memory_store`, `memory_wake_up`, `memory_profile`, `memory_stats`, …
- **SessionStart hook** — injects a compact wake-up brief every session
  (and again right after compaction).
- **PreCompact hook** — saves the conversation tail *before* compact.
- **Stop hook** — autosaves the turn tail (verbatim, local MiniLM only —
  **no cloud LLM compression**).
- **Skill `using-memory`** — index → get token discipline + when to store.
- **Slash commands** — `/remember <fact>` and `/recall <query>`.

### vs claude-mem

| | memxt | claude-mem |
|--|--|--|
| Capture | SessionStart + PreCompact + **Stop** | Many hooks + PostToolUse stream |
| Compress | **None** (verbatim + local embed) | Claude/Gemini/OpenRouter SDK |
| Search | Hybrid vec+FTS in one binary | FTS + optional Chroma + worker |
| Runtime | ~7MB Zig + MiniLM | Node + Bun + worker service |
| Multi-agent | One palace (Claude/Codex/Cursor/Grok) | Claude-first product |

Same job (Claude stops forgetting). Different bet: **local kernel**, not session-compressor SaaS-adjacent stack.

## Install

1. Install the engine (single static binary + 45 MB embedding model, fully local):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/Yupcha/memxt/main/install.sh | bash
   ```

2. Add the plugin in Claude Code:

   ```
   /plugin marketplace add Yupcha/memxt
   /plugin install memxt
   ```

That's it. Memory lives in a single global palace at `~/.memxt/palace.db`.

## Seed memory from a codebase (optional)

```bash
MEMXT_DB=~/.memxt/palace.db \
MEMXT_MODEL=~/.memxt/lib/minilm.gguf \
~/.memxt/bin/memxt mine . my-project
```

## Privacy

Embeddings, storage, and search all run on-device. No API keys, no network calls at
query time. Your code and memories stay on your machine.
