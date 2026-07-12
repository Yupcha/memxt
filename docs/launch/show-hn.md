# Show HN: memxt – local memory for Claude Code (and every coding agent)

*Ready to paste. Builder voice, continuity-first.*

---

**Title:** Show HN: memxt – local long-term memory for Claude Code (no cloud)

**Text:**

Every Claude Code session starts amnesiac. I re-explain architecture, re-state why we chose SQLite, and after compact the agent still undoes last week’s decision.

Cloud memory layers (and many “local” plugins) fix amnesia by shipping chat to a memory API or by running an extra LLM to compress every tool call. I wanted a **coding-agent kernel**: MCP tools, real hooks, one local SQLite palace shared with Codex / Cursor / Grok CLI — **nothing leaves the machine, no memory LLM bill**.

So I built **memxt**.

```bash
curl -fsSL https://raw.githubusercontent.com/Yupcha/memxt/main/install.sh | bash
```

In Claude Code:

```
/plugin marketplace add Yupcha/memxt
/plugin install memxt
```

Or wire every agent at once:

```bash
~/.memxt/bin/memxt adopt --write    # mine + Cursor/Codex/Grok snippets
~/.memxt/bin/memxt serve            # localhost monitor UI
```

### What you get

- **SessionStart** injects a continuity brief (~10 ms, no model load)
- **PreCompact + Stop** autosave the conversation tail (verbatim + on-device MiniLM — **not** Claude/Gemini compression)
- **Progressive recall** — `memory_search` (cheap index) → `memory_get` (full body by id)
- **Hybrid search** — vectors + FTS5 (great for `0x5C` / identifiers) + facts
- **Profiles & supersession** — “we use Postgres” → “we use SQLite” resolves
- **Dream** — hot budget + **4-bit** cold vectors (~6× smaller) so history stays bounded
- Fully **local**: one binary, SQLite, zero memory API key

### vs the big Claude memory plugin

[claude-mem](https://github.com/thedotmack/claude-mem) is excellent Claude Code autopilot. memxt is the other bet: **same continuity job**, multi-agent one palace, **no cloud LLM in the memory loop**.

### Does continuity actually work?

```bash
./scripts/bench-continuity.sh
# SCORE 6/6 — paraphrase recall of cart-cap / SQLite / Redis ban / auth cookies
```

Token savings on this repo (real agent path, not a synthetic leaderboard):

- Without: ~9.6k tokens of doc dump  
- With: ~2.7k wake + targeted search → **~72% less**  
  Details: `docs/TOKEN_SAVINGS.md`

### What it isn’t

Not a cloud SaaS, not “#1 LongMemEval,” not a full agent runtime. It’s the **local memory kernel for coding agents** so Claude Code (and friends) stop starting from zero.

Repo: https://github.com/Yupcha/memxt  
MIT. Feedback welcome — especially if you live in Claude Code daily.
