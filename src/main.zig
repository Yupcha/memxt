// ═══════════════════════════════════════════════════════════════════
// memxt — Local-first AI Memory System (Zig 0.16)
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const palace = @import("palace.zig");
const miner = @import("miner.zig");
const searcher = @import("searcher.zig");
const embedder = @import("embedder.zig");
const knowledge = @import("knowledge.zig");
const config = @import("config.zig");
const mcp = @import("mcp.zig");
const wakeup = @import("wakeup.zig");
const hooks = @import("hooks.zig");

const c_env = @cImport({
    @cInclude("stdlib.h");
});

/// Zig 0.16 "Juicy Main" — receives allocator, args, IO from the runtime.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var cfg = config.load(allocator, init.io) catch config.Config{};
    defer cfg.deinit(allocator);
    config.applyEnvOverrides(&cfg, allocator);

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_it.deinit();
    _ = args_it.next(); // skip argv[0] (program name)

    const command = args_it.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "init")) {
        try cmdInit(&cfg);
    } else if (std.mem.eql(u8, command, "mine")) {
        try embedder.initGlobal(cfg.model_path);
        defer embedder.deinitGlobal();

        const path = args_it.next() orelse {
            std.debug.print("Usage: memxt mine <path> [wing]\n", .{});
            return;
        };
        const wing = args_it.next() orelse cfg.default_wing;
        try cmdMine(init.io, path, wing, &cfg, allocator);
    } else if (std.mem.eql(u8, command, "search")) {
        try embedder.initGlobal(cfg.model_path);
        defer embedder.deinitGlobal();

        const query = args_it.next() orelse {
            std.debug.print("Usage: memxt search <query>\n", .{});
            return;
        };
        try cmdSearch(query, &cfg, allocator, init.io);
    } else if (std.mem.eql(u8, command, "stats")) {
        try cmdStats(&cfg, allocator);
    } else if (std.mem.eql(u8, command, "kg")) {
        const subject = args_it.next();
        try cmdKnowledgeGraph(subject, &cfg, allocator);
    } else if (std.mem.eql(u8, command, "wake-up")) {
        const wing = args_it.next();
        try cmdWakeUp(wing, &cfg, allocator);
    } else if (std.mem.eql(u8, command, "hook")) {
        try cmdHook(&cfg, allocator);
    } else if (std.mem.eql(u8, command, "embdbg")) {
        try embedder.initGlobal(cfg.model_path);
        defer embedder.deinitGlobal();
        const a = args_it.next() orelse "the cat sat on the mat";
        const b = args_it.next() orelse "a feline rested upon the rug";
        const va = try embedder.embed(a, allocator);
        defer allocator.free(va);
        const vb = try embedder.embed(b, allocator);
        defer allocator.free(vb);
        var dot: f32 = 0;
        for (va, vb) |x, y| dot += x * y;
        std.debug.print("dim={d}  |a|first3=[{d:.4} {d:.4} {d:.4}]  |b|first3=[{d:.4} {d:.4} {d:.4}]  cos={d:.4}\n", .{
            va.len, va[0], va[1], va[2], vb[0], vb[1], vb[2], dot,
        });
    } else if (std.mem.eql(u8, command, "instructions")) {
        try cmdInstructions(&args_it, allocator);
    } else if (std.mem.eql(u8, command, "mcp")) {
        // The model loads lazily on the first semantic search (see mcp.zig), so
        // `initialize` answers instantly and the client never times us out
        // waiting on cold Metal shader compilation. We still free it on exit.
        defer embedder.deinitGlobal();

        try mcp.serve(allocator, &cfg, init.io);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\
        \\  🏛️  memxt — Local-first AI Memory System (Zig Native Engine)
        \\
        \\  Usage:
        \\    memxt init                  Initialize palace database
        \\    memxt mine <path> [wing]    Mine files into the palace
        \\    memxt search <query>        Semantic search
        \\    memxt stats                 Palace statistics
        \\    memxt kg [subject]          Query knowledge graph
        \\    memxt wake-up [--wing X]    Show L0+L1 wake-up context
        \\    memxt hook                  Run hook (JSON stdin/stdout)
        \\    memxt instructions [--harness <claude|codex|cursor|zed|generic>]
        \\                                 Output setup instructions for an AI harness
        \\    memxt mcp                   Start MCP JSON-RPC server
        \\
    , .{});
}

fn openDb(cfg: *const config.Config) !db.Database {
    return db.Database.open(cfg.database_path.ptr);
}

fn cmdInit(cfg: *const config.Config) !void {
    std.debug.print("Initializing memxt database...\n", .{});
    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema();
    std.debug.print("✓ Palace is ready.\n", .{});
}

fn cmdMine(io: std.Io, path: [:0]const u8, wing_name: []const u8, cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema();

    var pal = palace.Palace.init(&database, allocator);

    std.debug.print("Mining '{s}' into wing '{s}'...\n", .{ path, wing_name });

    var stats: miner.MineStats = undefined;

    // Discriminate directory vs file by trying to open it AS a directory.
    // (openFile succeeds on directories in this IO model, so it can't be the
    // discriminator — that was the v0.1 "mine <dir> finds 0 files" bug.)
    if (std.Io.Dir.cwd().openDir(io, path, .{})) |dir_handle| {
        var d = dir_handle;
        d.close(io);
        stats = try miner.mineDirectory(&pal, path, .{ .wing_name = wing_name }, io, allocator);
    } else |_| {
        // It's a single file. JSON/JSONL → conversation export; otherwise document.
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".json") or std.ascii.eqlIgnoreCase(ext, ".jsonl")) {
            stats = try miner.mineConversation(&pal, path, wing_name, io, allocator);
        } else {
            stats = try miner.mineFile(&pal, path, wing_name, io, allocator);
        }
    }

    std.debug.print(
        \\✓ Mining complete.
        \\  Files processed: {}
        \\  Drawers created: {}
        \\  Files skipped:   {}
        \\  Bytes processed: {}
        \\
    , .{ stats.files_processed, stats.drawers_created, stats.files_skipped, stats.bytes_processed });

    if (stats.errors > 0) {
        std.debug.print("  ⚠ {} chunk(s) failed to embed/store — see warnings above; that content was NOT remembered.\n", .{stats.errors});
    }
}

fn cmdSearch(query: [:0]const u8, cfg: *const config.Config, allocator: std.mem.Allocator, io: std.Io) !void {
    var database = try openDb(cfg);
    defer database.close();

    var pal = palace.Palace.init(&database, allocator);

    std.debug.print("Searching for: '{s}'\n\n", .{query});

    const q_vec = try embedder.embed(query, allocator);
    defer allocator.free(q_vec);

    const results = try searcher.searchHybrid(&pal, query, q_vec, .{}, allocator, io);
    defer {
        for (results) |res| {
            allocator.free(res.content);
            allocator.free(res.source_path);
            allocator.free(res.wing_name);
            allocator.free(res.room_name);
        }
        allocator.free(results);
    }

    if (results.len == 0) {
        std.debug.print("No results found in the palace.\n", .{});
        return;
    }

    for (results, 0..) |res, i| {
        std.debug.print("─── Result {d} ───\n", .{i + 1});
        std.debug.print("Wing: {s}  Room: {s}  Score: {d:.4}\n", .{ res.wing_name, res.room_name, res.score });
        std.debug.print("Source: {s}\n", .{res.source_path});

        const len = @min(res.content.len, 200);
        std.debug.print("{s}...\n\n", .{res.content[0..len]});
    }
}

fn cmdStats(cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var database = try openDb(cfg);
    defer database.close();

    var pal = palace.Palace.init(&database, allocator);

    const stat_str = try pal.stats(allocator);
    defer allocator.free(stat_str);

    std.debug.print("{s}\n", .{stat_str});
}

fn cmdKnowledgeGraph(subject: ?[:0]const u8, cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var database = try openDb(cfg);
    defer database.close();

    var graph = knowledge.Graph.init(&database, allocator);

    const results = try graph.query(subject, null);
    defer {
        for (results) |r| {
            allocator.free(r.subject);
            allocator.free(r.predicate);
            allocator.free(r.object);
        }
        allocator.free(results);
    }

    if (results.len == 0) {
        std.debug.print("No knowledge graph entries found.\n", .{});
        return;
    }

    for (results) |r| {
        std.debug.print("{s} —[{s}]→ {s}  (confidence: {d:.2})\n", .{
            r.subject, r.predicate, r.object, r.confidence,
        });
    }
}

fn cmdWakeUp(wing: ?[:0]const u8, cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var database = try openDb(cfg);
    defer database.close();

    const wing_slice: ?[]const u8 = if (wing) |w| w[0..w.len] else null;
    const context = try wakeup.generate(&database, wing_slice, allocator);
    defer allocator.free(context);

    std.debug.print("{s}", .{context});
}

fn cmdHook(cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema();

    // PreCompact auto-save lazily loads the embedder; free it before exit so
    // ggml-metal's static destructor doesn't abort on un-released resources.
    defer embedder.deinitGlobal();

    try hooks.processHook(&database, cfg, allocator);
}

const Harness = enum {
    claude,
    codex,
    cursor,
    zed,
    generic,

    fn parse(name: []const u8) ?Harness {
        if (std.mem.eql(u8, name, "claude")) return .claude;
        if (std.mem.eql(u8, name, "codex")) return .codex;
        if (std.mem.eql(u8, name, "cursor")) return .cursor;
        if (std.mem.eql(u8, name, "zed")) return .zed;
        if (std.mem.eql(u8, name, "generic")) return .generic;
        return null;
    }
};

/// Resolve `$HOME` at runtime (Codex's TOML and some other harnesses don't
/// expand `${HOME}` themselves, so we bake in the real absolute path). Falls
/// back to the literal string "$HOME" if the environment variable is unset.
fn resolvedHome(allocator: std.mem.Allocator) ![]const u8 {
    if (c_env.getenv("HOME")) |home_ptr| {
        return try allocator.dupe(u8, std.mem.span(home_ptr));
    }
    return try allocator.dupe(u8, "$HOME");
}

fn cmdInstructions(args_it: *std.process.Args.Iterator, allocator: std.mem.Allocator) !void {
    var harness: Harness = .generic;

    if (args_it.next()) |flag| {
        if (std.mem.eql(u8, flag, "--harness")) {
            const name = args_it.next() orelse {
                std.debug.print("Usage: memxt instructions [--harness <claude|codex|cursor|zed|generic>]\n", .{});
                std.process.exit(1);
            };
            harness = Harness.parse(name) orelse {
                std.debug.print(
                    "Unknown harness '{s}'. Valid values: claude, codex, cursor, zed, generic\n",
                    .{name},
                );
                std.process.exit(1);
            };
        } else {
            std.debug.print(
                "Unknown flag '{s}'. Usage: memxt instructions [--harness <claude|codex|cursor|zed|generic>]\n",
                .{flag},
            );
            std.process.exit(1);
        }
    }

    switch (harness) {
        .generic => printGenericInstructions(),
        .claude => printClaudeInstructions(),
        .codex => try printCodexInstructions(allocator),
        .cursor => try printCursorInstructions(allocator),
        .zed => try printZedInstructions(allocator),
    }
}

fn printGenericInstructions() void {
    const instructions =
        \\# memxt — Memory Instructions
        \\
        \\You have a persistent, local-first memory palace. It survives across
        \\sessions and never leaves this machine. Content is organized into Wings
        \\(projects/domains) → Rooms (topics) → Drawers (verbatim chunks).
        \\
        \\## MCP tools (preferred, inside an agent)
        \\- `memory_search` — semantic recall; call BEFORE answering about prior work.
        \\- `memory_store`  — persist a decision, constraint, or snippet (verbatim).
        \\- `memory_wake_up`— load the compact continuity brief.
        \\- `memory_stats`  — palace statistics.
        \\
        \\## CLI (scripting / seeding)
        \\- `memxt mine <path> [wing]` — ingest a file or directory.
        \\- `memxt search "<query>"`   — semantic search.
        \\- `memxt wake-up [--wing X]` — print the wake-up context.
        \\
        \\## Best practices
        \\1. Recall before you answer anything about past decisions or conventions.
        \\2. After a real decision or a correction, store it as one crisp memory.
        \\3. Keep memories specific and self-contained.
        \\
        \\Nothing leaves the local machine. No API keys required.
        \\
        \\Using a different harness (Codex, Cursor, Zed)? Run
        \\`memxt instructions --harness <claude|codex|cursor|zed>` for copy-pasteable
        \\setup, or see docs/harnesses.md.
        \\
    ;
    std.debug.print("{s}", .{instructions});
}

fn printClaudeInstructions() void {
    const instructions =
        \\# memxt — Claude Code Setup
        \\
        \\Claude Code gets the full experience via the bundled plugin — MCP tools,
        \\session hooks, a skill, and slash commands — with zero manual wiring:
        \\
        \\  /plugin marketplace add Yupcha/memxt
        \\  /plugin install memxt
        \\
        \\That's it. This installs:
        \\  - `memory_search`, `memory_store`, `memory_wake_up`, `memory_stats` (MCP)
        \\  - A SessionStart hook that auto-injects the wake-up brief every session
        \\  - A PreCompact hook that saves the conversation tail before it's compacted
        \\  - `/remember` and `/recall` slash commands
        \\  - The `using-memory` skill, so Claude knows when to recall/store
        \\
        \\Optionally seed memory from a codebase:
        \\
        \\  ~/.memxt/bin/memxt mine . my-project
        \\
        \\See docs/harnesses.md for details on other harnesses.
        \\
    ;
    std.debug.print("{s}", .{instructions});
}

fn printCodexInstructions(allocator: std.mem.Allocator) !void {
    const home = try resolvedHome(allocator);
    defer allocator.free(home);

    std.debug.print(
        \\# memxt — OpenAI Codex CLI Setup
        \\
        \\Codex has no built-in memory hooks, so two things are needed: standing
        \\instructions telling the agent WHEN to use memory, and an MCP server entry
        \\telling Codex HOW to reach it.
        \\
        \\## 1. Standing instructions — add to AGENTS.md (project or ~/.codex/AGENTS.md)
        \\
        \\```markdown
        \\## Memory (memxt)
        \\
        \\You have a persistent, local memory palace via the `memory` MCP server. It
        \\survives across sessions and never leaves this machine. Four tools:
        \\
        \\- `memory_wake_up` — call this at the start of every session to load the
        \\  compact continuity brief. Codex does not auto-inject it like Claude Code
        \\  does, so you must call it yourself.
        \\- `memory_search` — semantic recall. Call this *before* answering any
        \\  question about prior work, past decisions, project conventions, or "how
        \\  did we do X". Don't assume you don't know — check memory first.
        \\- `memory_store` — persist something worth remembering: a decision and its
        \\  rationale, a non-obvious constraint, a key snippet, a fact about the user
        \\  or project. Store it verbatim and concise.
        \\- `memory_stats` — how much is stored.
        \\
        \\Recall before you answer anything about past decisions or conventions. After
        \\a real decision or a correction, store it as one crisp memory.
        \\```
        \\
        \\## 2. MCP server — add to ~/.codex/config.toml
        \\
        \\Codex's TOML config does not expand `$HOME`/`${{HOME}}`, so the path below is
        \\already resolved to your actual home directory:
        \\
        \\```toml
        \\[mcp_servers.memory]
        \\command = "{s}/.memxt/bin/memxt"
        \\args = ["mcp"]
        \\env = {{ MEMXT_DB = "{s}/.memxt/palace.db", MEMXT_MODEL = "{s}/.memxt/lib/minilm.gguf" }}
        \\```
        \\
        \\Restart Codex after editing config.toml. Nothing leaves the local machine.
        \\
    , .{ home, home, home });
}

fn printCursorInstructions(allocator: std.mem.Allocator) !void {
    const home = try resolvedHome(allocator);
    defer allocator.free(home);

    std.debug.print(
        \\# memxt — Cursor Setup
        \\
        \\## 1. MCP server — create .cursor/mcp.json (project) or ~/.cursor/mcp.json (global)
        \\
        \\```json
        \\{{
        \\  "mcpServers": {{
        \\    "memory": {{
        \\      "command": "{s}/.memxt/bin/memxt",
        \\      "args": ["mcp"],
        \\      "env": {{
        \\        "MEMXT_DB": "{s}/.memxt/palace.db",
        \\        "MEMXT_MODEL": "{s}/.memxt/lib/minilm.gguf"
        \\      }}
        \\    }}
        \\  }}
        \\}}
        \\```
        \\
        \\(The absolute path above is resolved to your actual home directory — Cursor's
        \\`${{HOME}}` expansion support varies by version, so this is the safe form.)
        \\
        \\## 2. Standing instructions — add to .cursorrules or a Project Rule
        \\
        \\```markdown
        \\## Memory (memxt)
        \\
        \\You have a persistent, local memory palace via the `memory` MCP server. It
        \\survives across sessions and never leaves this machine.
        \\
        \\- `memory_wake_up` — call at the start of a session to load the compact
        \\  continuity brief. Cursor does not auto-inject it, so call it yourself.
        \\- `memory_search` — semantic recall; call BEFORE answering about prior work,
        \\  past decisions, or project conventions.
        \\- `memory_store` — persist a decision, constraint, or snippet, verbatim.
        \\- `memory_stats` — palace statistics.
        \\```
        \\
        \\Reload the MCP servers list in Cursor's settings after adding the file.
        \\
    , .{ home, home, home });
}

fn printZedInstructions(allocator: std.mem.Allocator) !void {
    const home = try resolvedHome(allocator);
    defer allocator.free(home);

    std.debug.print(
        \\# memxt — Zed Setup
        \\
        \\## 1. MCP server — add to settings.json (Zed: Open Settings)
        \\
        \\```json
        \\{{
        \\  "context_servers": {{
        \\    "memory": {{
        \\      "source": "custom",
        \\      "command": {{
        \\        "path": "{s}/.memxt/bin/memxt",
        \\        "args": ["mcp"],
        \\        "env": {{
        \\          "MEMXT_DB": "{s}/.memxt/palace.db",
        \\          "MEMXT_MODEL": "{s}/.memxt/lib/minilm.gguf"
        \\        }}
        \\      }}
        \\    }}
        \\  }}
        \\}}
        \\```
        \\
        \\## 2. Standing instructions — add to your Zed rules (Assistant Panel → Rules)
        \\
        \\```markdown
        \\## Memory (memxt)
        \\
        \\You have a persistent, local memory palace via the `memory` MCP server. It
        \\survives across sessions and never leaves this machine.
        \\
        \\- `memory_wake_up` — call at the start of a thread to load the compact
        \\  continuity brief. Zed does not auto-inject it, so call it yourself.
        \\- `memory_search` — semantic recall; call BEFORE answering about prior work,
        \\  past decisions, or project conventions.
        \\- `memory_store` — persist a decision, constraint, or snippet, verbatim.
        \\- `memory_stats` — palace statistics.
        \\```
        \\
    , .{ home, home, home });
}

// ═══════════════════════════════════════════════════════════════════
// Testing Suite Entrypoint
// Requires tests cleanly resolving inside explicitly referenced files
// ═══════════════════════════════════════════════════════════════════

test "memxt unified testing suite" {
    _ = @import("db.zig");
    // Add additional explicit module testing dependencies below here
}

