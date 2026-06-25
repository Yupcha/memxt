# Awesome-list submissions

Ready-to-submit entries for memxt. The MCP one is the strongest fit and
worth submitting first; the rest land best right after the Show HN, when there's
some traction (many awesome-lists expect a little maturity).

## 1. punkpeye/awesome-mcp-servers → "🧠 Knowledge & Memory"

Insert alphabetically (by `author/name`):

```
- [Yupcha/memxt](https://github.com/Yupcha/memxt) 🏠 🍎 🐧 - Local-first long-term memory for AI coding agents in a single static Zig binary (llama.cpp + sqlite-vec). On-device embeddings, semantic recall, verbatim storage — no cloud, no vector DB, nothing leaves your machine. Ships a Claude Code plugin (memory tools + session hooks).
```

Legend: 🏠 local service · 🍎 macOS · 🐧 Linux.

## 2. hesreallyhim/awesome-claude-code → tooling / MCP section

```
- [memxt](https://github.com/Yupcha/memxt) - Persistent, local-first memory for Claude Code: an MCP memory server plus SessionStart/PreCompact hooks that auto-load context at session start and auto-save before compaction. One static binary, fully on-device.
```

## 3. catppuccin/awesome-zig (or zigcc/awesome-zig) → Applications / Tools

```
- [memxt](https://github.com/Yupcha/memxt) - Local-first long-term memory engine for AI coding agents. Statically links llama.cpp + sqlite-vec into one binary; MCP server + Claude Code plugin.
```

## How to submit (per list)

```bash
gh repo fork <owner>/<repo> --clone --remote
cd <repo>
# edit the README, add the entry in the right section
git checkout -b add-memxt
git commit -am "Add memxt (local-first agent memory)"
git push -u origin add-memxt
gh pr create --repo <owner>/<repo> --title "Add memxt" --body "..."
```

Timing: submit #1 now; submit #2 and #3 right after the Show HN front-pages.
