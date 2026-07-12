# Token savings: Grok (and other agents) with vs without memxt

**Goal:** Reduce session token usage by retrieving only what is needed from local memory,
instead of re-pasting or re-reading project docs every session.

**Measured on:** this machine’s palace (`~/.memxt/palace.db`, wing `memxt`) after wiring
Grok + mining the memxt repo + storing session decisions.

**Tokenizer:** `tiktoken` `cl100k_base` (Grok’s exact tokenizer differs slightly; **ratios** hold).

Raw numbers → [`TOKEN_SAVINGS.json`](./TOKEN_SAVINGS.json). Re-run:

```bash
# (script embedded in CI docs; regenerate by re-running the measurement from docs/TOKEN_SAVINGS.md history)
export MEMXT_DB=$HOME/.memxt/palace.db MEMXT_MODEL=$HOME/.memxt/lib/minilm.gguf
# See measurement procedure below
```

---

## Same work (what we compared)

Agent must **restore continuity** and answer **5 decision questions**:

1. How do we wire Grok CLI to memxt?  
2. Product positioning — Claude Code or Zig?  
3. Storage stack and why SQLite?  
4. What is schema v5 and what does dream do?  
5. Where is the palace DB and default wing?

### Without memxt

| Strategy | Tokens | Meaning |
|--|--:|--|
| **Full project dump** | **9,623** | README + ROADMAP + AGENTS + BENCHMARK + harness docs + session recap — typical “paste context” or bulk Read |
| Re-dump every question (×5) | 48,115 | Naive agent re-Reads the pack each turn |
| Hand-written recap only | 176 | Optimistic; only works if you already wrote a perfect recap |

### With memxt (tool results only)

| Step | Tokens |
|--|--:|
| `memory_wake_up` once | **1,281** |
| `memory_profile` once | 287 |
| 5× `memory_search` (limit 3) | **1,422** total (119–619 each) |
| **Wake + 5 searches** | **2,703** |

---

## Headline result

| | Tokens |
|--|--:|
| **Without** — full docs dump once, then answer 5 Qs | **9,623** |
| **With** — wake_up + 5 searches | **2,703** |
| **Saved** | **6,920** |
| **Reduction** | **71.9%** |
| **Ratio** | **~3.6× fewer tokens** |

```
WITHOUT ████████████████████████████████████  9,623
WITH    ██████████                            2,703
SAVED   71.9%
```

### Other fair cuts

| Scenario | Without | With | Saved |
|--|--:|--:|--:|
| Session restart only (dump vs wake_up) | 9,623 | 1,281 | **86.7%** |
| Dump vs wake + profile | 9,623 | 1,568 | **83.7%** |
| Re-Read dump every Q vs wake+searches | 48,115 | 2,703 | **94.4%** |

### Caveat (honest)

A **tiny hand-written recap (176 tokens)** is smaller than wake+5 searches — but:

1. You only have that recap if you already did the work and summarized it.  
2. Real amnesiac sessions **don’t** start with a perfect recap; they re-Read the repo or fail.  
3. Recap **does not scale** as the project grows; memxt retrieval stays ~constant size.

Fair baseline for “same quality without memxt” = **project docs dump** (or tool-based re-Read), not a magic 176-token summary.

---

## How this saves Grok tokens in practice

| Without memxt | With memxt |
|--|--|
| Paste README / ask model to Read many files | `memory_wake_up` (~1.3k tokens) |
| Re-explain architecture every session | Profile + decisions already in L1 |
| Search codebase for “what did we decide” | `memory_search` ~100–600 tokens / Q |
| Context fills with stale dumps | Context stays small; history lives on disk |

**Multiplier effect over a week:** if you restart 10 sessions and re-dump 9.6k each time  
→ **~96k tokens** without memxt vs **~13k** with wake-only restarts (**~86% saved** on continuity alone).

---

## How to reproduce

```bash
export MEMXT_DB=$HOME/.memxt/palace.db
export MEMXT_MODEL=$HOME/.memxt/lib/minilm.gguf

# Ensure palace is seeded (see README Grok wire-up)
~/.memxt/bin/memxt wake-up --wing memxt | wc -c
~/.memxt/bin/memxt search "Grok wire" --wing memxt --limit 3 | wc -c

# Continuity quality still holds:
./scripts/bench-continuity.sh
```

Tokenize with:

```python
import tiktoken
enc = tiktoken.get_encoding("cl100k_base")
len(enc.encode(open("somefile").read()))
```

---

## Tips to save even more

1. Prefer **`memory_profile`** (~300 tokens) before broad search when asking about conventions.  
2. Use **`mode=facts`** for short structured answers.  
3. Cap search **`limit=3`** (default in MCP is 5 — lower for Grok).  
4. Keep wake-up lean: store crisp `decisions` rooms; avoid mining huge vendored trees.  
5. Run **`memxt dream`** so cold history doesn’t bloat unfocused dumps (search stays targeted).

---

## Bottom line

For **restoring project continuity and answering 5 real decision questions** on this repo:

> **memxt used ~2.7k tokens of tool context vs ~9.6k tokens of doc dump — about 72% fewer tokens (~3.6× reduction), with structured recall from the local palace.**
