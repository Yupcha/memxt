# Awesome-list submissions

Pitch **Claude Code / coding agents / local memory**. Submit in this order **after** `v0.3.0` is live on GitHub Releases.

## 1. awesome-claude-code (highest priority)

```
- [memxt](https://github.com/Yupcha/memxt) - Persistent local memory for Claude Code: MCP tools + SessionStart/PreCompact/Stop hooks, progressive search (`memory_search` → `memory_get`), project profiles, hybrid FTS+vector, localhost monitor. Shared palace for Codex/Cursor/Grok. No cloud memory LLM.
```

## 2. punkpeye/awesome-mcp-servers → Knowledge & Memory

```
- [Yupcha/memxt](https://github.com/Yupcha/memxt) 🏠 🍎 🐧 - Long-term memory for Claude Code and coding agents. Local MCP + session hooks; progressive disclosure; hybrid vector/FTS/facts; dream consolidation with 4-bit cold vectors; monitor UI on localhost. Nothing leaves your machine.
```

## 3. Agent / AI memory lists

```
- [memxt](https://github.com/Yupcha/memxt) - Local-first memory for agentic coding tools (Claude Code, Codex, Cursor, Grok CLI). Continuity bench 6/6; ~72% fewer tokens vs doc dump; adopt --write; serve UI; multi-project wings in one palace.
```

## PR body template

```
## memxt

Local long-term memory for Claude Code and other coding agents.

- Claude plugin: MCP + SessionStart / PreCompact / Stop hooks
- Progressive recall: compact index → full drawer by id
- Verbatim storage + on-device MiniLM (no cloud LLM compression)
- Hybrid search (vector + FTS5 + facts), profiles, dream hot/cold
- One SQLite palace shared across Claude / Codex / Cursor / Grok
- Continuity bench 6/6; measured ~72% token savings vs pasting docs

Install: `curl -fsSL https://raw.githubusercontent.com/Yupcha/memxt/main/install.sh | bash`

https://github.com/Yupcha/memxt
```
