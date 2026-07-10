# Using memxt with other harnesses

memxt speaks plain MCP over stdio, so it works with any MCP client. Claude Code gets
the polished experience via the [`claude-plugin`](../claude-plugin) — MCP tools, a
SessionStart hook that auto-injects the wake-up brief, a PreCompact hook, a skill, and
slash commands, all wired up by `/plugin install memxt`.

**Other harnesses don't have hooks**, so nothing auto-injects memory at session start.
Two things stand in for that:

1. An **MCP server entry** so the harness can spawn `memxt mcp` and see the tools
   (`memory_search`, `memory_store`, `memory_wake_up`, `memory_stats`).
2. A **standing-instructions file** (`AGENTS.md`, `.cursorrules`, a Zed rule, …) telling
   the agent to call `memory_wake_up` itself at the start of a session/thread, and to
   call `memory_search` / `memory_store` proactively. Without this file, the agent has
   the tools but no reason to reach for them.

The fastest way to get both, with your real home directory already baked in, is:

```bash
memxt instructions --harness codex    # or: cursor | zed | claude | generic
```

This prints copy-pasteable config plus the instructions block — pipe it straight into
the target file, or paste by hand. What follows is the same content, spelled out.

## OpenAI Codex CLI

**1. MCP server** — add to `~/.codex/config.toml`. Codex's TOML parser does not expand
`$HOME` or `${HOME}`, so use the literal absolute path:

```toml
[mcp_servers.memory]
command = "/ABSOLUTE/HOME/.memxt/bin/memxt"
args = ["mcp"]
env = { MEMXT_DB = "/ABSOLUTE/HOME/.memxt/palace.db", MEMXT_MODEL = "/ABSOLUTE/HOME/.memxt/lib/minilm.gguf" }
```

**2. Standing instructions** — add to `AGENTS.md` (project root, or `~/.codex/AGENTS.md`
for a global default):

```markdown
## Memory (memxt)

You have a persistent, local memory palace via the `memory` MCP server. It
survives across sessions and never leaves this machine. Four tools:

- `memory_wake_up` — call this at the start of every session to load the
  compact continuity brief. Codex does not auto-inject it like Claude Code
  does, so you must call it yourself.
- `memory_search` — semantic recall. Call this *before* answering any
  question about prior work, past decisions, project conventions, or "how
  did we do X". Don't assume you don't know — check memory first.
- `memory_store` — persist something worth remembering: a decision and its
  rationale, a non-obvious constraint, a key snippet, a fact about the user
  or project. Store it verbatim and concise.
- `memory_stats` — how much is stored.

Recall before you answer anything about past decisions or conventions. After
a real decision or a correction, store it as one crisp memory.
```

Restart Codex after editing `config.toml`.

## Cursor

**1. MCP server** — create `.cursor/mcp.json` (project-scoped) or `~/.cursor/mcp.json`
(global):

```json
{
  "mcpServers": {
    "memory": {
      "command": "/ABSOLUTE/HOME/.memxt/bin/memxt",
      "args": ["mcp"],
      "env": {
        "MEMXT_DB": "/ABSOLUTE/HOME/.memxt/palace.db",
        "MEMXT_MODEL": "/ABSOLUTE/HOME/.memxt/lib/minilm.gguf"
      }
    }
  }
}
```

`${HOME}` expansion support varies by Cursor version, so `memxt instructions --harness
cursor` emits the resolved absolute path directly — safest across versions.

**2. Standing instructions** — add to `.cursorrules` or a Project Rule:

```markdown
## Memory (memxt)

You have a persistent, local memory palace via the `memory` MCP server. It
survives across sessions and never leaves this machine.

- `memory_wake_up` — call at the start of a session to load the compact
  continuity brief. Cursor does not auto-inject it, so call it yourself.
- `memory_search` — semantic recall; call BEFORE answering about prior work,
  past decisions, or project conventions.
- `memory_store` — persist a decision, constraint, or snippet, verbatim.
- `memory_stats` — palace statistics.
```

Reload the MCP servers list in Cursor's settings after adding the file.

## Zed

**1. MCP server** — add a `context_servers` block to `settings.json`:

```json
{
  "context_servers": {
    "memory": {
      "source": "custom",
      "command": {
        "path": "/ABSOLUTE/HOME/.memxt/bin/memxt",
        "args": ["mcp"],
        "env": {
          "MEMXT_DB": "/ABSOLUTE/HOME/.memxt/palace.db",
          "MEMXT_MODEL": "/ABSOLUTE/HOME/.memxt/lib/minilm.gguf"
        }
      }
    }
  }
}
```

**2. Standing instructions** — add to your Zed rules (Assistant Panel → Rules):

```markdown
## Memory (memxt)

You have a persistent, local memory palace via the `memory` MCP server. It
survives across sessions and never leaves this machine.

- `memory_wake_up` — call at the start of a thread to load the compact
  continuity brief. Zed does not auto-inject it, so call it yourself.
- `memory_search` — semantic recall; call BEFORE answering about prior work,
  past decisions, or project conventions.
- `memory_store` — persist a decision, constraint, or snippet, verbatim.
- `memory_stats` — palace statistics.
```

## Any other MCP client

Point it at:

```
command: memxt   (or the absolute path to the installed binary)
args:    ["mcp"]
env:     MEMXT_DB=~/.memxt/palace.db  MEMXT_MODEL=~/.memxt/lib/minilm.gguf
```

That's the full server contract — no other flags. Then write your own standing
instructions using the wording above, since the wake-up brief is only auto-injected on
Claude Code (via its SessionStart hook); everywhere else, the AGENTS.md/rules file is
what makes the agent proactively call `memory_wake_up` and `memory_search`.

## Reference: the one-liner

```bash
memxt instructions            # generic instructions + pointer to this doc
memxt instructions --harness claude
memxt instructions --harness codex
memxt instructions --harness cursor
memxt instructions --harness zed
```

Unknown `--harness` values print the valid list to stderr and exit non-zero.
