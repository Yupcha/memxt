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
const inspect_mod = @import("inspect.zig");
const dream_mod = @import("dream.zig");
const serve_mod = @import("serve.zig");
const telemetry = @import("telemetry.zig");

const c_env = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
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
        // Lazy model load: pure incremental re-mines skip every embed and never
        // pay Metal init. setModelPath records where to load from on first use.
        embedder.setModelPath(cfg.model_path);
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
        try cmdSearch(&args_it, &cfg, allocator, init.io);
    } else if (std.mem.eql(u8, command, "stats")) {
        try cmdStats(&cfg, allocator);
    } else if (std.mem.eql(u8, command, "inspect")) {
        try cmdInspect(&cfg, allocator);
    } else if (std.mem.eql(u8, command, "adopt")) {
        try cmdAdopt(&args_it, &cfg, allocator, init.io);
    } else if (std.mem.eql(u8, command, "dream")) {
        embedder.setModelPath(cfg.model_path);
        defer embedder.deinitGlobal();
        try cmdDream(&args_it, &cfg, allocator);
    } else if (std.mem.eql(u8, command, "kg")) {
        const subject = args_it.next();
        try cmdKnowledgeGraph(subject, &cfg, allocator);
    } else if (std.mem.eql(u8, command, "wake-up")) {
        try cmdWakeUp(&args_it, &cfg, allocator);
    } else if (std.mem.eql(u8, command, "forget")) {
        try cmdForget(&args_it, &cfg, allocator);
    } else if (std.mem.eql(u8, command, "export")) {
        try cmdExport(&args_it, &cfg, allocator, init.io);
    } else if (std.mem.eql(u8, command, "import")) {
        embedder.setModelPath(cfg.model_path);
        defer embedder.deinitGlobal();
        try cmdImport(&args_it, &cfg, allocator, init.io);
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
    } else if (std.mem.eql(u8, command, "serve")) {
        defer embedder.deinitGlobal();
        try cmdServe(&args_it, &cfg, allocator);
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
        \\  🏛️  memxt — Long-term memory for Claude Code & coding agents
        \\
        \\  Usage:
        \\    memxt adopt [--no-mine] [--harness all|claude|codex|cursor|grok|zed]
        \\                                         Wire agents + optionally mine cwd
        \\    memxt init                           Initialize palace database
        \\    memxt mine <path> [wing]             Mine files (incremental)
        \\    memxt search <query> [options]       Hybrid FTS + vector search
        \\         --limit N  --wing NAME  --format plain|json|md
        \\    memxt wake-up [--wing NAME] [--budget TOKENS]  L0+L1+L2 continuity brief
        \\    memxt inspect                        Palace health (facts, profile, kinds)
        \\    memxt dream [--budget N] [--dry-run] Consolidate: demote cold, clusters, expire
        \\    memxt forget <id|--wing NAME>        Evict a drawer or whole wing
        \\    memxt export [path] [--wing NAME]    JSONL dump
        \\    memxt import <path>                  Re-ingest a JSONL export
        \\    memxt stats                          Palace statistics
        \\    memxt kg [subject]                   Query knowledge graph
        \\    memxt hook                           Claude Code hook (JSON stdin/stdout)
        \\    memxt serve [--port N]               Localhost monitor UI (127.0.0.1)
        \\    memxt instructions --harness <…>     claude|codex|cursor|grok|zed|generic
        \\    memxt mcp                            MCP server (stdio) for agents
        \\
        \\  search options: --mode hybrid|memories|documents|facts|episodes
        \\                  --as-of UNIX_TS   --limit N   --wing NAME   --format …
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
        \\  Chunks skipped:  {}  (already stored — incremental)
        \\  Files skipped:   {}
        \\  Bytes processed: {}
        \\
    , .{ stats.files_processed, stats.drawers_created, stats.chunks_skipped, stats.files_skipped, stats.bytes_processed });

    if (stats.errors > 0) {
        std.debug.print("  ⚠ {} chunk(s) failed to embed/store — see warnings above; that content was NOT remembered.\n", .{stats.errors});
    }
}

const SearchFormat = enum { plain, json, md };

fn cmdSearch(args_it: *std.process.Args.Iterator, cfg: *const config.Config, allocator: std.mem.Allocator, io: std.Io) !void {
    var query: ?[:0]const u8 = null;
    var limit: i32 = 10;
    var wing: ?[]const u8 = null;
    var format: SearchFormat = .plain;
    var mode: searcher.SearchMode = .hybrid;
    var as_of: ?i64 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--limit")) {
            const v = args_it.next() orelse {
                std.debug.print("--limit requires a number\n", .{});
                return;
            };
            limit = std.fmt.parseInt(i32, v, 10) catch {
                std.debug.print("Invalid --limit '{s}'\n", .{v});
                return;
            };
            limit = @intCast(std.math.clamp(limit, 1, 100));
        } else if (std.mem.eql(u8, arg, "--wing")) {
            wing = args_it.next() orelse {
                std.debug.print("--wing requires a name\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--mode")) {
            const v = args_it.next() orelse {
                std.debug.print("--mode requires hybrid|memories|documents|facts|episodes\n", .{});
                return;
            };
            mode = searcher.SearchMode.parse(v) orelse {
                std.debug.print("Unknown --mode '{s}'\n", .{v});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--as-of")) {
            const v = args_it.next() orelse {
                std.debug.print("--as-of requires a unix timestamp\n", .{});
                return;
            };
            as_of = std.fmt.parseInt(i64, v, 10) catch {
                std.debug.print("Invalid --as-of '{s}'\n", .{v});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--format")) {
            const v = args_it.next() orelse {
                std.debug.print("--format requires plain|json|md\n", .{});
                return;
            };
            if (std.mem.eql(u8, v, "json")) format = .json else if (std.mem.eql(u8, v, "md")) format = .md else if (std.mem.eql(u8, v, "plain")) format = .plain else {
                std.debug.print("Unknown --format '{s}' (use plain|json|md)\n", .{v});
                return;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown flag '{s}'. Usage: memxt search <query> [--mode …] [--as-of TS] [--limit N] [--wing NAME] [--format …]\n", .{arg});
            return;
        } else if (query == null) {
            query = arg;
        } else {
            std.debug.print("Unexpected argument '{s}'\n", .{arg});
            return;
        }
    }

    const q = query orelse {
        std.debug.print("Usage: memxt search <query> [--mode hybrid|memories|documents|facts|episodes] [--as-of TS] …\n", .{});
        return;
    };

    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema(); // ensure FTS migration runs

    var pal = palace.Palace.init(&database, allocator);

    if (format == .plain) {
        std.debug.print("Searching for: '{s}'  (mode={s})\n\n", .{ q, mode.name() });
    }

    var q_vec: []const f32 = &[_]f32{};
    var q_owned = false;
    if (mode != .facts) {
        q_vec = try embedder.embed(q, allocator);
        q_owned = true;
    }
    defer if (q_owned) allocator.free(q_vec);

    // Default wing for facts mode so structured recall works.
    const wing_eff: ?[]const u8 = wing orelse if (mode == .facts or mode == .hybrid) blk: {
        if (!std.mem.eql(u8, cfg.default_wing, "default")) break :blk cfg.default_wing;
        break :blk wing;
    } else wing;

    const results = try searcher.search(&pal, q, q_vec, .{
        .limit = limit,
        .wing = wing_eff,
        .mode = mode,
        .as_of = as_of,
    }, allocator, io);
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
        if (format == .json) {
            std.debug.print("[]\n", .{});
        } else {
            std.debug.print("No results found in the palace.\n", .{});
        }
        return;
    }

    // Usage telemetry: these drawer ids were surfaced (best-effort;
    // facts mode returns fact ids, not drawers).
    if (mode != .facts) {
        for (results) |res| telemetry.recordSurfaced(&database, res.drawer_id);
    }

    switch (format) {
        .json => {
            const Hit = struct {
                id: i64,
                wing: []const u8,
                room: []const u8,
                source: []const u8,
                score: f64,
                content: []const u8,
            };
            const hits = try allocator.alloc(Hit, results.len);
            defer allocator.free(hits);
            for (results, 0..) |r, i| {
                hits[i] = .{
                    .id = r.drawer_id,
                    .wing = r.wing_name,
                    .room = r.room_name,
                    .source = r.source_path,
                    .score = r.score,
                    .content = r.content,
                };
            }
            const json = try std.json.Stringify.valueAlloc(allocator, hits, .{});
            defer allocator.free(json);
            std.debug.print("{s}\n", .{json});
        },
        .md => {
            for (results, 0..) |res, i| {
                std.debug.print("### {d}. #{d} · {s}/{s} · score {d:.4}\n", .{ i + 1, res.drawer_id, res.wing_name, res.room_name, res.score });
                std.debug.print("Source: `{s}`\n\n{s}\n\n", .{ res.source_path, res.content });
            }
        },
        .plain => {
            for (results, 0..) |res, i| {
                std.debug.print("─── Result {d} ───\n", .{i + 1});
                std.debug.print("Id: {d}  Wing: {s}  Room: {s}  Score: {d:.4}\n", .{ res.drawer_id, res.wing_name, res.room_name, res.score });
                std.debug.print("Source: {s}\n", .{res.source_path});
                const len = @min(res.content.len, 400);
                const dots: []const u8 = if (res.content.len > 400) "..." else "";
                std.debug.print("{s}{s}\n\n", .{ res.content[0..len], dots });
            }
        },
    }
}

fn cmdStats(cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema();

    var pal = palace.Palace.init(&database, allocator);

    const stat_str = try pal.stats(allocator);
    defer allocator.free(stat_str);

    std.debug.print("{s}\n", .{stat_str});
}

fn cmdInspect(cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema();

    const report = try inspect_mod.render(&database, cfg.database_path, allocator);
    defer allocator.free(report);
    std.debug.print("{s}", .{report});
}

fn cmdServe(args_it: *std.process.Args.Iterator, cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var opts = serve_mod.ServeOptions{};
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const v = args_it.next() orelse {
                std.debug.print("--port requires a number\n", .{});
                return;
            };
            opts.port = std.fmt.parseInt(u16, v, 10) catch {
                std.debug.print("Invalid --port\n", .{});
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Usage: memxt serve [--port 8765]\n", .{});
            return;
        }
    }
    try serve_mod.run(cfg, opts, allocator);
}

fn cmdDream(args_it: *std.process.Args.Iterator, cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var opts = dream_mod.DreamOptions{};
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--budget")) {
            const v = args_it.next() orelse {
                std.debug.print("--budget requires a number\n", .{});
                return;
            };
            opts.hot_budget = std.fmt.parseInt(i64, v, 10) catch {
                std.debug.print("Invalid --budget\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--wing")) {
            opts.wing = args_it.next();
        } else if (std.mem.eql(u8, arg, "--no-clusters")) {
            opts.build_clusters = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Usage: memxt dream [--budget N] [--dry-run] [--wing NAME] [--no-clusters]\n", .{});
            return;
        }
    }

    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema();

    // Clusters benefit from embeddings when model can load.
    embedder.initGlobal(cfg.model_path) catch {};

    std.debug.print("🌙 Dreaming{s}…\n", .{if (opts.dry_run) " (dry-run)" else ""});
    const report = try dream_mod.run(&database, opts, allocator);
    const text = try dream_mod.formatReport(report, allocator);
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
}

/// Wire coding agents to this palace and optionally mine the current directory.
fn cmdAdopt(args_it: *std.process.Args.Iterator, cfg: *const config.Config, allocator: std.mem.Allocator, io: std.Io) !void {
    var do_mine = true;
    var do_write = false;
    var harness_filter: []const u8 = "all";

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-mine")) {
            do_mine = false;
        } else if (std.mem.eql(u8, arg, "--write")) {
            do_write = true;
        } else if (std.mem.eql(u8, arg, "--harness")) {
            harness_filter = args_it.next() orelse "all";
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Usage: memxt adopt [--no-mine] [--write] [--harness all|claude|codex|cursor|grok|zed]\n", .{});
            return;
        }
    }

    std.debug.print("🏛️  memxt adopt — local memory for coding agents\n\n", .{});

    // 1) Ensure palace exists
    {
        var database = try openDb(cfg);
        defer database.close();
        database.createPalaceSchema();
        std.debug.print("✓ Palace ready: {s}\n", .{cfg.database_path});
    }

    // 2) Mine cwd into project wing
    if (do_mine) {
        embedder.setModelPath(cfg.model_path);
        defer embedder.deinitGlobal();
        std.debug.print("… Mining current directory into wing '{s}'…\n", .{cfg.default_wing});
        cmdMine(io, ".", cfg.default_wing, cfg, allocator) catch |err| {
            std.debug.print("⚠ Mine skipped/failed: {s}\n", .{@errorName(err)});
        };
    } else {
        std.debug.print("• Skipping mine (--no-mine)\n", .{});
    }

    // 3) Print harness wiring
    const home = try resolvedHome(allocator);
    defer allocator.free(home);

    std.debug.print("\n═══ Wire your coding agents (same local palace) ═══\n\n", .{});

    const show_all = std.mem.eql(u8, harness_filter, "all");
    if (show_all or std.mem.eql(u8, harness_filter, "claude")) {
        std.debug.print(
            \\── Claude Code (best experience) ──
            \\  /plugin marketplace add Yupcha/memxt
            \\  /plugin install memxt
            \\
            \\  Plugin uses MEMXT_DB / MEMXT_MODEL. Ensure:
            \\    export MEMXT_DB="{s}/.memxt/palace.db"
            \\    export MEMXT_MODEL="{s}/.memxt/lib/minilm.gguf"
            \\  (or rely on install paths if you used the curl installer)
            \\
        , .{ home, home });
    }
    if (show_all or std.mem.eql(u8, harness_filter, "codex")) {
        std.debug.print(
            \\── Codex CLI — ~/.codex/config.toml ──
            \\[mcp_servers.memory]
            \\command = "{s}/.memxt/bin/memxt"
            \\args = ["mcp"]
            \\env = {{ MEMXT_DB = "{s}", MEMXT_MODEL = "{s}/.memxt/lib/minilm.gguf" }}
            \\
            \\  Also add the Memory block to AGENTS.md:
            \\    memxt instructions --harness codex
            \\
        , .{ home, cfg.database_path, home });
    }
    if (show_all or std.mem.eql(u8, harness_filter, "cursor")) {
        std.debug.print(
            \\── Cursor — .cursor/mcp.json or ~/.cursor/mcp.json ──
            \\{{
            \\  "mcpServers": {{
            \\    "memory": {{
            \\      "command": "{s}/.memxt/bin/memxt",
            \\      "args": ["mcp"],
            \\      "env": {{
            \\        "MEMXT_DB": "{s}",
            \\        "MEMXT_MODEL": "{s}/.memxt/lib/minilm.gguf"
            \\      }}
            \\    }}
            \\  }}
            \\}}
            \\
        , .{ home, cfg.database_path, home });
    }
    if (show_all or std.mem.eql(u8, harness_filter, "grok")) {
        std.debug.print(
            \\── Grok CLI — ~/.grok/config.toml ──
            \\[mcp_servers.memory]
            \\command = "{s}/.memxt/bin/memxt"
            \\args = ["mcp"]
            \\env = {{ MEMXT_DB = "{s}", MEMXT_MODEL = "{s}/.memxt/lib/minilm.gguf" }}
            \\enabled = true
            \\startup_timeout_sec = 60
            \\
            \\  Standing rules: call memory_wake_up at session start; memory_search
            \\  before past-work answers; memory_store after decisions.
            \\  (Or: memxt instructions --harness grok)
            \\
        , .{ home, cfg.database_path, home });
    }
    if (show_all or std.mem.eql(u8, harness_filter, "zed")) {
        std.debug.print(
            \\── Zed — settings.json context_servers ──
            \\  Run: memxt instructions --harness zed
            \\
        , .{});
    }

    if (do_write) {
        std.debug.print("\n═══ Writing harness configs (--write) ═══\n", .{});
        try writeHarnessConfigs(home, cfg, harness_filter, allocator, io);
    }

    std.debug.print(
        \\═══ Next ═══
        \\  memxt inspect          # palace health
        \\  memxt wake-up          # preview session brief
        \\  memxt dream            # compress hot index (TurboQuant cold vecs)
        \\  In Claude Code: ask about a past decision after /plugin install
        \\  Tip: memxt adopt --write   # auto-write Codex/Grok/Cursor MCP snippets
        \\
        \\One palace for every coding agent. Nothing leaves this machine.
        \\
    , .{});
}

fn writeHarnessConfigs(home: []const u8, cfg: *const config.Config, filter: []const u8, allocator: std.mem.Allocator, io: std.Io) !void {
    const show_all = std.mem.eql(u8, filter, "all");
    const bin = try std.fmt.allocPrint(allocator, "{s}/.memxt/bin/memxt", .{home});
    defer allocator.free(bin);
    const model = try std.fmt.allocPrint(allocator, "{s}/.memxt/lib/minilm.gguf", .{home});
    defer allocator.free(model);
    const db_path = cfg.database_path;

    if (show_all or std.mem.eql(u8, filter, "cursor")) {
        _ = c_env.mkdir(".cursor", 0o755);
        const body = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "mcpServers": {{
            \\    "memory": {{
            \\      "command": "{s}",
            \\      "args": ["mcp"],
            \\      "env": {{
            \\        "MEMXT_DB": "{s}",
            \\        "MEMXT_MODEL": "{s}"
            \\      }}
            \\    }}
            \\  }}
            \\}}
            \\
        , .{ bin, db_path, model });
        defer allocator.free(body);
        writeHomeFile(".cursor/mcp.json", body, io) catch |err| {
            std.debug.print("⚠ could not write .cursor/mcp.json: {}\n", .{err});
        };
        std.debug.print("✓ wrote .cursor/mcp.json\n", .{});
    }

    if (show_all or std.mem.eql(u8, filter, "codex")) {
        // Append snippet file the user can include — don't clobber full config.toml
        const path = try std.fmt.allocPrint(allocator, "{s}/.codex/memxt-mcp.toml.snippet", .{home});
        defer allocator.free(path);
        const body = try std.fmt.allocPrint(allocator,
            \\# Add to ~/.codex/config.toml (generated by memxt adopt --write)
            \\[mcp_servers.memory]
            \\command = "{s}"
            \\args = ["mcp"]
            \\env = {{ MEMXT_DB = "{s}", MEMXT_MODEL = "{s}" }}
            \\
        , .{ bin, db_path, model });
        defer allocator.free(body);
        writeHomeFile(path, body, io) catch |err| {
            std.debug.print("⚠ could not write Codex snippet: {}\n", .{err});
        };
        // Standing instructions helper
        const agents = try std.fmt.allocPrint(allocator, "{s}/.codex/memxt-AGENTS.snippet.md", .{home});
        defer allocator.free(agents);
        const agents_body =
            \\## Memory (memxt)
            \\
            \\You have a persistent local memory palace via the `memory` MCP server.
            \\- `memory_wake_up` — start of every session
            \\- `memory_profile` — project facts (fast)
            \\- `memory_search` — before past-work answers (`mode`: hybrid|memories|facts)
            \\- `memory_store` — after decisions (room `decisions`)
            \\- `memory_dream` — optional consolidation
            \\
        ;
        writeHomeFile(agents, agents_body, io) catch {};
        std.debug.print("✓ wrote {s}\n", .{path});
        std.debug.print("✓ wrote {s}\n", .{agents});
    }

    if (show_all or std.mem.eql(u8, filter, "grok")) {
        const path = try std.fmt.allocPrint(allocator, "{s}/.grok/memxt-mcp.toml.snippet", .{home});
        defer allocator.free(path);
        const body = try std.fmt.allocPrint(allocator,
            \\# Add to ~/.grok/config.toml (generated by memxt adopt --write)
            \\[mcp_servers.memory]
            \\command = "{s}"
            \\args = ["mcp"]
            \\env = {{ MEMXT_DB = "{s}", MEMXT_MODEL = "{s}" }}
            \\enabled = true
            \\startup_timeout_sec = 60
            \\
        , .{ bin, db_path, model });
        defer allocator.free(body);
        writeHomeFile(path, body, io) catch |err| {
            std.debug.print("⚠ could not write Grok snippet: {}\n", .{err});
        };
        std.debug.print("✓ wrote {s}\n", .{path});
    }

    if (show_all or std.mem.eql(u8, filter, "claude")) {
        std.debug.print("• Claude Code: use `/plugin install memxt` (plugin manages MCP+hooks)\n", .{});
    }
}

fn writeHomeFile(path: []const u8, body: []const u8, io: std.Io) !void {
    _ = io;
    if (std.fs.path.dirname(path)) |dir| {
        const dir_z = try std.heap.c_allocator.dupeZ(u8, dir);
        defer std.heap.c_allocator.free(dir_z);
        _ = c_env.mkdir(dir_z.ptr, 0o755);
    }
    const path_z = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(path_z);
    const f = c_stdio.fopen(path_z.ptr, "w") orelse return error.FileOpenFailed;
    defer _ = c_stdio.fclose(f);
    if (body.len > 0) {
        const n = c_stdio.fwrite(body.ptr, 1, body.len, f);
        if (n != body.len) return error.WriteFailed;
    }
}

const c_stdio = @cImport({
    @cInclude("stdio.h");
});

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

fn cmdWakeUp(args_it: *std.process.Args.Iterator, cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var wing: ?[]const u8 = null;
    var budget: ?usize = null;
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--wing")) {
            wing = args_it.next() orelse {
                std.debug.print("--wing requires a name\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--budget")) {
            const v = args_it.next() orelse {
                std.debug.print("--budget requires a token count\n", .{});
                return;
            };
            budget = std.fmt.parseInt(usize, v, 10) catch {
                std.debug.print("Invalid token budget '{s}'. Use a positive number.\n", .{v});
                return;
            };
            if (budget.? == 0) budget = null;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown flag '{s}'. Usage: memxt wake-up [--wing NAME] [--budget TOKENS]\n", .{arg});
            return;
        } else {
            // Positional wing for backward compat: `wake-up my-project`
            wing = arg;
        }
    }
    // Default to project-derived wing so sessions don't mix unrelated work.
    if (wing == null and !std.mem.eql(u8, cfg.default_wing, "default")) {
        wing = cfg.default_wing;
    }

    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema();

    const context = try wakeup.generateBudgeted(&database, wing, budget, allocator);
    defer allocator.free(context);

    std.debug.print("{s}", .{context});
}

fn cmdForget(args_it: *std.process.Args.Iterator, cfg: *const config.Config, allocator: std.mem.Allocator) !void {
    var wing: ?[]const u8 = null;
    var id: ?i64 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--wing")) {
            wing = args_it.next() orelse {
                std.debug.print("--wing requires a name\n", .{});
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Usage: memxt forget <drawer-id> | memxt forget --wing NAME\n", .{});
            return;
        } else {
            id = std.fmt.parseInt(i64, arg, 10) catch {
                std.debug.print("Invalid drawer id '{s}'. Use a number or --wing NAME.\n", .{arg});
                return;
            };
        }
    }

    if (wing == null and id == null) {
        std.debug.print("Usage: memxt forget <drawer-id> | memxt forget --wing NAME\n", .{});
        return;
    }

    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema();
    var pal = palace.Palace.init(&database, allocator);

    if (wing) |w| {
        const n = try pal.deleteWing(w);
        std.debug.print("✓ Forgot wing '{s}' ({d} drawer{s}).\n", .{ w, n, if (n == 1) "" else "s" });
    } else if (id) |did| {
        const removed = try pal.deleteDrawer(did);
        if (removed) {
            std.debug.print("✓ Forgot memory #{d}.\n", .{did});
        } else {
            std.debug.print("No memory #{d} found.\n", .{did});
        }
    }
}

fn cmdExport(args_it: *std.process.Args.Iterator, cfg: *const config.Config, allocator: std.mem.Allocator, io: std.Io) !void {
    var out_path: ?[]const u8 = null;
    var wing: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--wing")) {
            wing = args_it.next() orelse {
                std.debug.print("--wing requires a name\n", .{});
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Usage: memxt export [path.jsonl] [--wing NAME]\n", .{});
            return;
        } else {
            out_path = arg;
        }
    }

    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema();
    var pal = palace.Palace.init(&database, allocator);

    const rows = try pal.listExportRows(wing, allocator);
    defer {
        for (rows) |row| {
            allocator.free(row.wing);
            allocator.free(row.room);
            allocator.free(row.content);
            allocator.free(row.source_path);
            allocator.free(row.source_type);
            allocator.free(row.content_hash);
        }
        allocator.free(rows);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (rows) |row| {
        const line = try std.json.Stringify.valueAlloc(allocator, .{
            .id = row.id,
            .wing = row.wing,
            .room = row.room,
            .content = row.content,
            .source_path = row.source_path,
            .source_type = row.source_type,
            .chunk_index = row.chunk_index,
            .content_hash = row.content_hash,
            .created_at = row.created_at,
        }, .{});
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
        try buf.append(allocator, '\n');
    }

    if (out_path) |path| {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, buf.items, 0);
        std.debug.print("✓ Exported {d} drawer{s} → {s}\n", .{ rows.len, if (rows.len == 1) "" else "s", path });
    } else {
        const stdout = std.Io.File.stdout();
        _ = stdout.writeStreamingAll(io, buf.items) catch {};
    }
}

fn cmdImport(args_it: *std.process.Args.Iterator, cfg: *const config.Config, allocator: std.mem.Allocator, io: std.Io) !void {
    const path = args_it.next() orelse {
        std.debug.print("Usage: memxt import <export.jsonl>\n", .{});
        return;
    };

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.debug.print("Cannot open '{s}': {}\n", .{ path, err });
        return;
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > 100 * 1024 * 1024) {
        std.debug.print("Import file too large (max 100MB).\n", .{});
        return;
    }
    const contents = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(contents);
    _ = try file.readPositionalAll(io, contents, 0);

    var database = try openDb(cfg);
    defer database.close();
    database.createPalaceSchema();
    var pal = palace.Palace.init(&database, allocator);

    var imported: u32 = 0;
    var skipped: u32 = 0;
    var errors: u32 = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            errors += 1;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            errors += 1;
            continue;
        }
        const obj = parsed.value.object;

        const content = switch (obj.get("content") orelse {
            errors += 1;
            continue;
        }) {
            .string => |s| s,
            else => {
                errors += 1;
                continue;
            },
        };
        if (content.len == 0) {
            skipped += 1;
            continue;
        }

        // Skip if hash already present (incremental import).
        var hash_buf: [64]u8 = undefined;
        if (palace.Palace.contentHashHex(content, &hash_buf)) |hex| {
            if (pal.hasContentHash(hex)) {
                skipped += 1;
                continue;
            }
        } else |_| {}

        const wing_name = jsonObjStr(obj, "wing") orelse cfg.default_wing;
        const room_name = jsonObjStr(obj, "room") orelse "imported";
        const source_path = jsonObjStr(obj, "source_path") orelse "import";
        const source_type = jsonObjStr(obj, "source_type") orelse "import";
        const chunk_index: i32 = blk: {
            const v = obj.get("chunk_index") orelse break :blk 0;
            break :blk switch (v) {
                .integer => |n| @intCast(std.math.clamp(n, 0, std.math.maxInt(i32))),
                else => 0,
            };
        };

        const wing_id = pal.createWing(wing_name, "", "import") catch {
            errors += 1;
            continue;
        };
        const room_id = pal.createRoom(wing_id, room_name, "") catch {
            errors += 1;
            continue;
        };
        const embedding = embedder.embed(content, allocator) catch {
            errors += 1;
            continue;
        };
        defer allocator.free(embedding);

        _ = pal.insertDrawer(room_id, content, source_path, source_type, chunk_index, embedding) catch {
            errors += 1;
            continue;
        };
        imported += 1;
    }

    std.debug.print("✓ Import complete: {d} imported, {d} skipped (dupes), {d} errors.\n", .{ imported, skipped, errors });
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
    grok,
    zed,
    generic,

    fn parse(name: []const u8) ?Harness {
        if (std.mem.eql(u8, name, "claude")) return .claude;
        if (std.mem.eql(u8, name, "codex")) return .codex;
        if (std.mem.eql(u8, name, "cursor")) return .cursor;
        if (std.mem.eql(u8, name, "grok")) return .grok;
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
                std.debug.print("Usage: memxt instructions [--harness <claude|codex|cursor|grok|zed|generic>]\n", .{});
                std.process.exit(1);
            };
            harness = Harness.parse(name) orelse {
                std.debug.print(
                    "Unknown harness '{s}'. Valid values: claude, codex, cursor, grok, zed, generic\n",
                    .{name},
                );
                std.process.exit(1);
            };
        } else {
            std.debug.print(
                "Unknown flag '{s}'. Usage: memxt instructions [--harness <claude|codex|cursor|grok|zed|generic>]\n",
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
        .grok => try printGrokInstructions(allocator),
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
        \\  - PreCompact + Stop hooks that autosave the conversation tail (local, no LLM)
        \\  - Progressive recall: memory_search (index) → memory_get (full body)
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

fn printGrokInstructions(allocator: std.mem.Allocator) !void {
    const home = try resolvedHome(allocator);
    defer allocator.free(home);

    std.debug.print(
        \\# memxt — Grok CLI (Grok Build) Setup
        \\
        \\Local MCP tool — same palace as Claude Code / Codex. Your Grok subscription
        \\only powers the model; memory stays on disk.
        \\
        \\## 1. MCP server — ~/.grok/config.toml
        \\
        \\```toml
        \\[mcp_servers.memory]
        \\command = "{s}/.memxt/bin/memxt"
        \\args = ["mcp"]
        \\env = {{ MEMXT_DB = "{s}/.memxt/palace.db", MEMXT_MODEL = "{s}/.memxt/lib/minilm.gguf" }}
        \\enabled = true
        \\startup_timeout_sec = 60
        \\```
        \\
        \\Or: `grok mcp add memory -- {s}/.memxt/bin/memxt mcp` then set env in config.
        \\
        \\## 2. Standing instructions — project rules
        \\
        \\```markdown
        \\## Memory (memxt)
        \\
        \\You have a persistent, local memory palace via the `memory` MCP server.
        \\
        \\- `memory_wake_up` — call at the start of every session
        \\- `memory_profile` — stable project facts (no model load)
        \\- `memory_search` — before answering about prior work or decisions
        \\- `memory_store` — after a real decision (prefer room "decisions")
        \\- `memory_forget` / `memory_stats` — cleanup and health
        \\```
        \\
        \\Use the same MEMXT_DB as Claude Code so all coding agents share one brain.
        \\
    , .{ home, home, home, home });
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

fn jsonObjStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

// ═══════════════════════════════════════════════════════════════════
// Testing Suite Entrypoint
// Requires tests cleanly resolving inside explicitly referenced files
// ═══════════════════════════════════════════════════════════════════

test "memxt unified testing suite" {
    _ = @import("db.zig");
    _ = @import("quant.zig");
    _ = @import("fleet.zig");
    _ = @import("packer.zig");
    _ = @import("telemetry.zig");
}

