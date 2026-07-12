# Launch pack — memxt

Ship as **coding-agent memory** (Claude Code first), not as “Zig binary.”

## One-liner pitch

> Claude Code forgets your decisions after compact. memxt doesn’t. Local MCP + hooks, shared across Codex/Cursor/Grok. Nothing leaves your machine — no memory LLM.

## Assets

| File | Use |
|--|--|
| [`show-hn.md`](./show-hn.md) | Show HN / Reddit post draft |
| [`demo.tape`](./demo.tape) | VHS tape for demo GIF re-record |
| [`demo/sample-project/`](./demo/sample-project/) | Tiny repo for live demos |
| [`../../packaging/awesome-entries.md`](../../packaging/awesome-entries.md) | Awesome-list PR bodies |
| [`../BENCHMARKS_CONTINUITY.md`](../BENCHMARKS_CONTINUITY.md) | Continuity bench |
| [`../TOKEN_SAVINGS.md`](../TOKEN_SAVINGS.md) | Measured token savings |
| [`../../scripts/bench-continuity.sh`](../../scripts/bench-continuity.sh) | Run continuity |
| [`../../scripts/bench-scale.sh`](../../scripts/bench-scale.sh) | Run scale + quant |

## Pre-flight checklist

```bash
# 1. Local build + benches
zig build --release=fast
./scripts/bench-continuity.sh          # expect SCORE 6/6
N=200 HOT_BUDGET=50 ./scripts/bench-scale.sh

# 2. Version + tag
# build.zig.zon version must match release tag (e.g. 0.3.0 → v0.3.0)
git push origin main
git tag v0.3.0 && git push origin v0.3.0   # triggers .github/workflows/release.yml

# 3. Wait for GitHub Release assets (4 tarballs)
gh release view v0.3.0

# 4. Fresh install smoke (uses published tarball)
curl -fsSL https://raw.githubusercontent.com/Yupcha/memxt/main/install.sh | bash
~/.memxt/bin/memxt init
~/.memxt/bin/memxt wake-up
# MCP tools: memory_search (index) → memory_get; hooks: SessionStart/PreCompact/Stop

# 5. GitHub About box
# Description: Local long-term memory for Claude Code & coding agents. MCP + hooks. Nothing leaves your machine.
# Topics: claude-code, mcp, ai-memory, local-first, agent-memory
```

## Channels (order)

1. **Show HN** — `show-hn.md` title + body (only after install smoke is green)
2. **awesome-claude-code** — first PR
3. **awesome-mcp-servers** — Knowledge & Memory
4. **r/ClaudeAI**, **r/LocalLLaMA**, **r/mcp**
5. X/Twitter: SessionStart wake-up + search → get GIF

## Do / don’t

| Do | Don’t |
|--|--|
| Lead with Claude Code amnesia | Lead with Zig |
| Show local + multi-agent same DB | Claim cloud SOTA LoCoMo |
| Contrast claude-mem honestly (no memory LLM) | Trash competitors |
| Link continuity + token savings | Fake placeholder-vector numbers |
| Mention `adopt --write` + progressive disclosure | Promise Drive/Gmail connectors |

## Scorecard (v0.3.0 target)

| Area | Ready when |
|--|--|
| Core product | Continuity 6/6 + MCP search/get |
| README story | Claude-first + vs claude-mem |
| Install path | `curl \| bash` hits **this** release |
| Version | `build.zig.zon` == release tag |
| Launch copy | show-hn + awesome refreshed |
| GitHub About | Description matches README pitch |

## Post-launch metrics

- Continuity SCORE 6/6 green in CI (optional later)
- Stars / plugin installs
- Issues: install, model path, harness wire-up, wing collisions
