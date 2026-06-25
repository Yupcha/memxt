# 🗺️ Roadmap — Parity & Outmatch

Path from `memxt` today to **full drop-in parity** with the upstream Python `mempalace` package, then to **outmatching** it with capabilities the Python stack cannot reach.

Legend: `[x]` done · `[~]` partial · `[ ]` planned

---

## Phase 0 — Shipped (v0.2)

Real, working local memory engine + Claude Code integration. Verified end-to-end
against Claude Code 2.1.191.

- [x] `init` / `stats` — palace DB bootstrap + pragma mapping
- [x] `mine <path> [wing]` — concurrent file ingestion; **directory walker fixed** (v0.1 mis-routed dirs to the conversation path → 0 files)
- [x] **Real on-device embeddings** — `llama.cpp` MiniLM-L6-v2 (384-dim), Metal/CUDA, mean-pooled + L2-normalized (was a placeholder dummy vector)
- [x] `search <query>` — `sqlite-vec` retrieval with **corrected hybrid scoring** (the old score was inverted → best match ranked last)
- [x] **Static linking fixed** — links the cmake-built `llama.cpp` `.a` archives, not Homebrew dylibs (which crashed with a duplicate-dylib error)
- [x] `wake-up [--wing X]` — L0+L1 context loader (~600–900 tok)
- [x] **`mcp` — real MCP server**: `memory_search` / `memory_store` / `memory_wake_up` / `memory_stats`, lazy model load, protocol-version echo (was a hardcoded stub)
- [x] **`hook` — real Claude Code protocol**: SessionStart injects wake-up via `additionalContext`; PreCompact reads the transcript and **auto-saves** the tail (was a custom protocol + a nag)
- [x] **Claude Code plugin** — `claude-plugin/` + marketplace manifest: MCP server + hooks + `using-memory` skill + `/remember` `/recall` commands; one global palace via `MEMXT_DB`/`_MODEL` env overrides
- [x] `kg [subject]` — knowledge-graph relationship query (manual population)
- [x] `instructions` — memory-instruction emitter
- [x] `mempalace.yaml` + `memxt.yaml` config + env-var overrides
- [x] MIT license, GitHub Actions CI, one-line curl installer (now fetches a **384-dim** model)
- [x] Honest benchmarks vs the real engine (`BENCHMARK.md`); retrieval 7/7 top-1 on a paraphrase test

---

## Phase 1 — Full Parity (v0.2)

Close every remaining gap with the upstream `pip install mempalace` surface. Each item blocks the "100% drop-in" claim.

> ⚠ Upstream CLI audit is still pending (PyPI fetch was blocked during planning). These items are inferred from project structure and the typical memory-tool surface. Cross-check against the upstream docs before cutting v0.2.

- [x] **Directory walker bug** — fixed in v0.2. Root cause was `cmdMine` using `openFile` to discriminate (it succeeds on directories in Zig 0.16's IO), mis-routing dirs to the conversation path; now discriminates with `openDir`.
- [ ] **`mine` flag parity** — `--wing`, `--room`, `--recursive`, `--ignore`, `--dry-run`
- [ ] **`search` flag parity** — `--limit`, `--wing`, `--format=json|md|plain`, similarity threshold
- [ ] **`init` vs `stats`** — upstream uses `init`; alias our `stats` where appropriate
- [ ] **Incremental re-mining** — content-hash skip for unchanged files (currently re-embeds all)
- [ ] **`forget <id|wing>`** — evict drawers
- [ ] **Export / import** — `memxt export <path>` JSONL dump + re-ingest round-trip
- [ ] **Ignore-pattern parity** — `.gitignore`-style globs matching upstream semantics
- [ ] **Config schema audit** — every upstream yaml key respected or rejected with a diagnostic
- [ ] **Python-parity output strings** — exit codes, stderr format, progress-bar layout for script consumers
- [ ] **Embedding model swap** — allow upstream's default model name via `model: <name>` resolving to HF URL

**Definition of done:** a user can `pip uninstall mempalace && curl ... | bash && ln -s .../memxt .../mempalace` and every script in their pipeline keeps working unchanged.

---

## Phase 2 — Outmatch (v0.3–v0.5)

Ship features upstream Python cannot match without rewriting. Each lands a capability bullet on the README.

### v0.3 — Performance Frontier

- [ ] **Batched embedding kernel** — vectorize mine across N files per GPU call (target: 10× mine throughput vs current 200×)
- [ ] **Incremental vector index** — sqlite-vec HNSW params tuned per drawer-count bucket
- [ ] **Zero-copy mmap ingest** — large file mining without full read-into-RAM
- [ ] **Compile-time schema** — Zig comptime validation of `memxt.yaml`; bad config fails at build, not runtime

### v0.4 — Reach Beyond CLI

- [ ] **Watch mode** — `memxt watch <path>` file-system events → auto re-mine (upstream Python blocks on ChromaDB lock; we don't)
- [ ] **Embedded HTTP API** — `memxt serve --port 8080` pure Zig handler, <5 MB RAM overhead
- [ ] **Web UI** — single-file static dashboard shipped inside binary (SQLite browser + search box)
- [ ] **Hybrid search** — BM25 + vector fusion (upstream is vector-only)
- [ ] **Time-scoped queries** — `--since 2026-01-01`, `--until`, decay-weighted ranking

### v0.5 — Ecosystem & Distribution

- [ ] **Homebrew formula** — `brew install memxt`
- [ ] **Docker image** — ~15 MB distroless image (vs upstream ~1.2 GB Python+ML)
- [ ] **Shell completions** — zsh / bash / fish
- [x] **Claude Code plugin** — `claude-plugin/` wires MCP + hooks + skill + slash commands (v0.2)
- [ ] **Plugin SDK** — stable `lib/memxt.h` C ABI for 3rd-party languages

### v0.6+ — Intelligence Layer

- [ ] **Auto-consolidation** — dream-cycle re-embedding to compact similar drawers
- [ ] **Knowledge-graph extraction** — NER on mine to auto-populate entity edges (currently manual)
- [ ] **Multi-modal** — image / PDF mining via local vision GGUFs
- [ ] **Federated palaces** — optional peer-to-peer sync between machines (E2E-encrypted)

---

## Non-goals

- Cloud SaaS or managed hosting
- Python-binding wrapper (keep the stack Zig-native; use the binary)
- ChromaDB / Pinecone / Weaviate compatibility shims
- Any feature that requires a network call at query time

---

## Contributing

Open an issue with the `roadmap` label. Phase 1 items that unblock the parity claim get priority over Phase 2+. Benchmark every perf claim against `BENCHMARK.md` methodology before merging.
