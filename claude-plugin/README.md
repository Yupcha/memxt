# memxt — Claude Code plugin

Gives Claude Code a persistent, **local-first** memory. Your agent remembers your
codebase, your decisions, and your conventions across sessions — and nothing ever
leaves your machine.

## What it adds

- **MCP server `memory`** with four tools: `memory_search`, `memory_store`,
  `memory_wake_up`, `memory_stats`.
- **SessionStart hook** — injects a compact "wake-up" brief of recent memory at the
  start of every session (and again right after compaction).
- **PreCompact hook** — saves the recent conversation *before* it's compacted away,
  so context survives.
- **Skill `using-memory`** — teaches Claude when to recall and when to persist.
- **Slash commands** — `/remember <fact>` and `/recall <query>`.

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
