<div align="center">
  <img src="assets/logo.svg" alt="Fast MemPalace Logo" width="350"/>
  <h1>fast-mempalace</h1>
  <p><b>Local-first long-term memory for AI coding agents.</b><br/>
  Your agent remembers your codebase and decisions across sessions — in a single static binary. No cloud, no Python, nothing leaves your machine.</p>
  <br/>
  <img src="assets/demo.gif" alt="fast-mempalace semantic recall demo" width="760"/>
</div>

---

Most AI coding sessions start amnesiac: you re-explain the architecture, re-state why
you chose SQLite over Postgres, and the agent still contradicts last week's decision.
**fast-mempalace** gives the agent a persistent, on-device memory it can search and
write to — wired into Claude Code via MCP tools and session hooks.

- 🧠 **Remembers across sessions** — semantic recall over everything you've mined or saved.
- 🔒 **Fully local & private** — embeddings, storage, and search run on-device (`llama.cpp` + `sqlite-vec`). No API keys, no network at query time.
- 📦 **One static binary** — no Python, no Docker, no vector database to run. ~6 MB + a 45 MB embedding model.
- ⚡ **Invisible in the loop** — session wake-up in ~10 ms; vector search is sub-millisecond once the model is resident.

## ⚡ Install

```bash
curl -fsSL https://raw.githubusercontent.com/debpalash/fast-mempalace/main/install.sh | bash
```

Detects `darwin|linux` × `x86_64|aarch64`. Binary + embedding model land in
`~/.fast-mempalace/`.

## 🤖 Use with Claude Code (the main event)

Install the plugin — it wires up the MCP memory tools, the session hooks, a skill, and
slash commands:

```text
/plugin marketplace add debpalash/fast-mempalace
/plugin install fast-mempalace
```

You now have:

| Surface | What it does |
|--|--|
| **`memory_search`** (MCP) | Semantic recall before answering about past work |
| **`memory_store`** (MCP) | Persist a decision, constraint, or snippet — verbatim |
| **`memory_wake_up`** (MCP) | Load the compact continuity brief |
| **SessionStart hook** | Auto-injects recent memory at the start of every session |
| **PreCompact hook** | Saves the conversation tail *before* it's compacted away |
| **`/remember`, `/recall`** | Slash commands for explicit save/recall |

Optionally seed memory from a codebase:

```bash
~/.fast-mempalace/bin/fast-mempalace mine . my-project
```

> Works with any MCP client (Cursor, Zed, Windsurf, …) too — point it at
> `fast-mempalace mcp`.

## 🧩 How it works

Content is organized as **Wings** (a project/domain) → **Rooms** (a topic) →
**Drawers** (a verbatim chunk + its embedding). Retrieval is vector similarity
(`sqlite-vec`, L2 over L2-normalized MiniLM-L6-v2 embeddings) with light recency and
keyword re-ranking. Everything is one SQLite file.

- **Bare-metal embeddings** — `llama.cpp` statically linked, Metal/CUDA accelerated.
- **Verbatim storage** — your memories are never silently rewritten or summarized by an LLM (and there's no graph-query injection surface to poison).
- **Concurrent mining** — files embed in parallel via `std.Io.Group`.

## 📊 Benchmarks

Apple Silicon · Metal · cold process unless noted. Methodology →
[`BENCHMARK.md`](./BENCHMARK.md).

| Operation | Time | Notes |
|--|--|--|
| Cold start (`stats`) | **0.01 s** | no model load |
| Session wake-up | **0.01 s** | recency SQL, no model load — runs every session |
| Mine (15 files → 31 drawers) | **~1.0 s** | real on-device MiniLM embeddings |
| Vector search | **sub-ms** | once the model is resident (e.g. the MCP server); ~0.5 s amortized model load on a one-shot CLI call |
| Peak RAM (search, model loaded) | **~100 MB** | mostly the embedding model |

> Honest note: earlier `0.59 s / 1171-drawer` numbers measured placeholder vectors.
> These figures are the real semantic engine. The cost of mining is dominated by
> embedding throughput, not I/O.

## 📦 CLI

```text
fast-mempalace init                  Initialize the palace database
fast-mempalace mine <path> [wing]    Mine a file or directory into the palace
fast-mempalace search <query>        Semantic search
fast-mempalace wake-up [--wing X]    Print the wake-up context
fast-mempalace stats                 Palace statistics
fast-mempalace mcp                   Start the MCP server (stdio JSON-RPC)
fast-mempalace hook                  Run a Claude Code hook (JSON stdin/stdout)
fast-mempalace kg [subject]          Query the knowledge graph
```

## ⚙️ Configuration

Reads `fast-mempalace.yaml` (falls back to `mempalace.yaml`). Environment variables
override everything — this is how the plugin pins one global palace regardless of the
project directory:

```bash
FAST_MEMPALACE_DB=~/.fast-mempalace/palace.db           # database path
FAST_MEMPALACE_MODEL=~/.fast-mempalace/lib/minilm.gguf  # 384-dim GGUF embedder
FAST_MEMPALACE_WING=my-project                          # default wing
```

```yaml
database_path: "fast-mempalace.db"
model_path: "lib/minilm.gguf"
default_wing: "production"
```

The embedding model must be **384-dim** (MiniLM-L6-v2); the vector table is declared
`float[384]` and the binary validates the model on load.

## 🔧 Build from source

Needs `zig 0.16.0` + `cmake`.

```bash
git clone --recursive https://github.com/debpalash/fast-mempalace
cd fast-mempalace

# 1) Build the statically-linked llama.cpp backend (once)
cmake -S lib/llama.cpp -B lib/llama.cpp/build \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF
cmake --build lib/llama.cpp/build -j

# 2) Fetch the 384-dim embedding model
mkdir -p lib && curl -L -o lib/minilm.gguf \
  "https://huggingface.co/leliuga/all-MiniLM-L6-v2-GGUF/resolve/main/all-MiniLM-L6-v2.F16.gguf"

# 3) Build
zig build --release=fast
./zig-out/bin/fast-mempalace stats
```

(On Linux, use `-DGGML_METAL=OFF -DGGML_BLAS=OFF`.)

## 🗺️ Roadmap

→ [`ROADMAP.md`](./ROADMAP.md).

## 📄 License

[MIT](./LICENSE).
