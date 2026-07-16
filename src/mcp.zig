// ═══════════════════════════════════════════════════════════════════
// memxt/mcp.zig — Model Context Protocol server (stdio JSON-RPC)
//
// Exposes the memory palace to any MCP-capable agent (Claude Code, Cursor,
// Zed, …) over newline-delimited JSON-RPC on stdin/stdout.
//
// Progressive disclosure (token-efficient, claude-mem-style, zero cloud LLM):
//   memory_search   — compact INDEX by default (~50–120 tokens/hit)
//   memory_get      — full drawer body by id(s) only when needed
//   memory_store    — persist a decision / snippet / fact as a memory
//   memory_forget   — delete a memory by its drawer id
//   memory_wake_up  — load the compact session-start context
//   memory_profile  — stable project facts (no model)
//   memory_dream    — hot/cold consolidation
//   memory_stats    — palace statistics
//
// Plus two prompts (remember / recall) and one resource (the wake-up brief).
// All work happens locally; nothing leaves the machine.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const db = @import("db.zig");
const palace = @import("palace.zig");
const miner = @import("miner.zig");
const searcher = @import("searcher.zig");
const embedder = @import("embedder.zig");
const wakeup = @import("wakeup.zig");
const profile_mod = @import("profile.zig");
const facts_mod = @import("facts.zig");
const dream_mod = @import("dream.zig");
const fleet = @import("fleet.zig");
const packer = @import("packer.zig");

const Allocator = std.mem.Allocator;

const RpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

const TOOLS_LIST =
    \\{
    \\  "tools": [
    \\    {
    \\      "name": "memory_search",
    \\      "description": "Hybrid semantic + keyword search of the local memory palace. DEFAULT detail=index returns a compact index (~id, path, ~100-char snippet) so you can filter before loading full text — progressive disclosure saves tokens. Use BEFORE answering about prior work. Then call memory_get on promising ids.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "query": { "type": "string", "description": "What to recall, in natural language." },
    \\          "limit": { "type": "integer", "description": "Max results (default 5).", "default": 5 },
    \\          "wing": { "type": "string", "description": "Limit search to one project/domain wing (optional)." },
    \\          "mode": { "type": "string", "description": "hybrid|memories|documents|facts|episodes (default hybrid)." },
    \\          "detail": { "type": "string", "description": "index (default, compact) | full (entire body in results)." },
    \\          "as_of": { "type": "integer", "description": "Unix timestamp for temporal fact queries (optional)." },
    \\          "budget_tokens": { "type": "integer", "description": "Budget mode: instead of the index list, return ONE packed markdown brief that fits this many tokens — dense facts first, then top bodies, trimmed at line boundaries. Drawer ids are kept so you can memory_get for more." }
    \\        },
    \\        "required": ["query"]
    \\      }
    \\    },
    \\    {
    \\      "name": "memory_get",
    \\      "description": "Fetch full verbatim memory body by drawer id(s). Use AFTER memory_search (detail=index) when a hit looks relevant. Batch multiple ids in one call.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "id": { "type": "integer", "description": "Single drawer id from memory_search." },
    \\          "ids": { "type": "array", "items": { "type": "integer" }, "description": "Batch of drawer ids (preferred)." }
    \\        }
    \\      }
    \\    },
    \\    {
    \\      "name": "memory_store",
    \\      "description": "Persist an important memory for future sessions: a decision and its rationale, a key code snippet, a constraint, a fact about the project or user. Store anything you'd want to remember next time. Content is kept verbatim. Prefer room 'decisions' for architecture choices so they appear in the wake-up profile.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "content": { "type": "string", "description": "The exact text to remember." },
    \\          "wing": { "type": "string", "description": "Project/domain bucket (default: current project)." },
    \\          "room": { "type": "string", "description": "Topic within the wing (default: notes). Use 'decisions' for durable choices." },
    \\          "source": { "type": "string", "description": "Who is writing, for fleet attribution: e.g. claude-code, subagent:verify-1, codex. Default: MEMXT_SOURCE env, else 'agent'." },
    \\          "scratch": { "type": "boolean", "description": "Session-scoped scratch memory: expires (default 24h, MEMXT_SCRATCH_TTL secs) at the next dream cycle unless memory_promote keeps it." }
    \\        },
    \\        "required": ["content"]
    \\      }
    \\    },
    \\    {
    \\      "name": "memory_wake_up",
    \\      "description": "Load the compact wake-up brief: L0 identity + L1 project profile (decisions) + L2 recent work (~600-1200 tokens). Call at the start of a session to recover continuity.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "wing": { "type": "string", "description": "Limit to one project/domain (defaults to current project wing)." },
    \\          "budget_tokens": { "type": "integer", "description": "Fit the brief to this token budget. Layers keep priority L0 identity > L1 profile > L2 recent work; the cut lands on a line boundary." }
    \\        }
    \\      }
    \\    },
    \\    {
    \\      "name": "memory_forget",
    \\      "description": "Delete a stored memory by its drawer id (the `id` field returned by memory_search). Removes both the content and its vector embedding so it can never surface again. Use when a memory is wrong, stale, or should not be retained.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "id": { "type": "integer", "description": "The drawer id to forget (from a memory_search result)." }
    \\        },
    \\        "required": ["id"]
    \\      }
    \\    },
    \\    {
    \\      "name": "memory_profile",
    \\      "description": "Load the project profile (stable facts and decisions) without semantic search. Fast (~ms), no embedding model. Call when you need who/what/conventions for this project.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "wing": { "type": "string", "description": "Project wing (defaults to current project)." }
    \\        }
    \\      }
    \\    },
    \\    {
    \\      "name": "memory_dream",
    \\      "description": "Run consolidation: expire stale facts, demote cold vectors under budget, build episode clusters. Keeps infinite history while bounding hot search cost.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "budget": { "type": "integer", "description": "Max hot vectors (default 50000)." },
    \\          "dry_run": { "type": "boolean", "description": "Report only, do not demote." }
    \\        }
    \\      }
    \\    },
    \\    {
    \\      "name": "memory_stats",
    \\      "description": "Report palace statistics: how many wings, rooms, drawers, and entities are stored.",
    \\      "inputSchema": { "type": "object", "properties": {} }
    \\    },
    \\    {
    \\      "name": "memory_promote",
    \\      "description": "Make a scratch memory durable: clears its expiry so it survives dream cleanup. Use when a scratch memory (memory_store with scratch=true) turned out to be worth keeping.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "id": { "type": "integer", "description": "Drawer id of the scratch memory (from memory_store / memory_search)." }
    \\        },
    \\        "required": ["id"]
    \\      }
    \\    }
    \\  ]
    \\}
;

// ── Prompts (portable /remember and /recall) ──
//
// Advertised via the `prompts` capability and served by prompts/list +
// prompts/get. The wording mirrors claude-plugin/commands/{remember,recall}.md
// so the slash commands behave identically on any MCP client.

const PROMPTS_LIST =
    \\{
    \\  "prompts": [
    \\    {
    \\      "name": "remember",
    \\      "description": "Save something to long-term local memory",
    \\      "arguments": [
    \\        { "name": "content", "description": "The text to remember (verbatim).", "required": true }
    \\      ]
    \\    },
    \\    {
    \\      "name": "recall",
    \\      "description": "Search long-term local memory and answer from it",
    \\      "arguments": [
    \\        { "name": "query", "description": "What to recall, in natural language.", "required": true }
    \\      ]
    \\    }
    \\  ]
    \\}
;

// ── Resources (the wake-up brief as an attachable resource) ──

const WAKEUP_URI = "memxt://wakeup";

const RESOURCES_LIST =
    \\{
    \\  "resources": [
    \\    {
    \\      "uri": "memxt://wakeup",
    \\      "name": "Memory wake-up brief",
    \\      "description": "Compact session-start context: L0 identity + L1 project profile + L2 recent work (~600-1200 tokens).",
    \\      "mimeType": "text/plain"
    \\    }
    \\  ]
    \\}
;

pub fn serve(allocator: Allocator, cfg: *const config.Config, io: std.Io) !void {
    var database = db.Database.open(cfg.database_path.ptr) catch {
        writeLine(io, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"failed to open palace database\"}}");
        return;
    };
    defer database.close();
    database.createPalaceSchema();
    fleet.ensureColumns(&database);

    var pal = palace.Palace.init(&database, allocator);

    const stdin = std.Io.File.stdin();
    var line_buf = std.ArrayListUnmanaged(u8).empty;
    defer line_buf.deinit(allocator);
    var chunk: [8192]u8 = undefined;

    while (true) {
        const n = stdin.readStreaming(io, &.{chunk[0..]}) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;
        try line_buf.appendSlice(allocator, chunk[0..n]);

        while (std.mem.indexOfScalar(u8, line_buf.items, '\n')) |nl| {
            const line = line_buf.items[0..nl];
            if (line.len > 0) handleLine(allocator, &pal, &database, cfg, io, line) catch {};
            // advance past the newline
            const remaining = line_buf.items.len - (nl + 1);
            std.mem.copyForwards(u8, line_buf.items[0..remaining], line_buf.items[nl + 1 ..]);
            line_buf.shrinkRetainingCapacity(remaining);
        }
    }
}

fn handleLine(
    allocator: Allocator,
    pal: *palace.Palace,
    database: *db.Database,
    cfg: *const config.Config,
    io: std.Io,
    line: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(RpcRequest, allocator, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();

    const req = parsed.value;
    const id = req.id orelse std.json.Value{ .null = {} };
    const method = req.method;

    if (std.mem.eql(u8, method, "initialize")) {
        // Echo the client's requested protocol version for compatibility — but
        // only if it's a safe version token. It's interpolated into a hand-built
        // JSON string, so an unescaped `"`/`\` would let the client inject
        // arbitrary response fields. Real versions look like "2024-11-05".
        var version: []const u8 = "2024-11-05";
        if (req.params) |pp| {
            if (pp == .object) {
                if (pp.object.get("protocolVersion")) |pv| {
                    if (pv == .string and isSafeVersion(pv.string)) version = pv.string;
                }
            }
        }
        const info = try std.fmt.allocPrint(allocator,
            \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{}},"prompts":{{}},"resources":{{}}}},"serverInfo":{{"name":"memxt","version":"{s}"}}}}
        , .{ version, build_options.version });
        defer allocator.free(info);
        try sendRawResult(allocator, io, id, info);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        // notification — no response
    } else if (std.mem.eql(u8, method, "ping")) {
        try sendRawResult(allocator, io, id, "{}");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try sendRawResult(allocator, io, id, TOOLS_LIST);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        var result = dispatchTool(allocator, pal, database, cfg, io, req.params) catch |err|
            ToolResult{ .text = try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}) };
        defer result.deinit(allocator);
        try sendToolResult(allocator, io, id, result);
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        try sendRawResult(allocator, io, id, PROMPTS_LIST);
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        try handlePromptGet(allocator, io, id, req.params);
    } else if (std.mem.eql(u8, method, "resources/list")) {
        try sendRawResult(allocator, io, id, RESOURCES_LIST);
    } else if (std.mem.eql(u8, method, "resources/read")) {
        try handleResourceRead(allocator, database, cfg, io, id, req.params);
    } else {
        try sendError(allocator, io, id, -32601, "method not found");
    }
}

// A tool result: always a human-readable `text` block (backward-compatible with
// the Claude Code plugin, which only reads text), plus an OPTIONAL `structured`
// JSON string embedded as MCP `structuredContent` for clients that can consume it.
const ToolResult = struct {
    text: []u8,
    structured: ?[]u8 = null,

    fn deinit(self: *ToolResult, allocator: Allocator) void {
        allocator.free(self.text);
        if (self.structured) |s| allocator.free(s);
    }
};

fn dispatchTool(
    allocator: Allocator,
    pal: *palace.Palace,
    database: *db.Database,
    cfg: *const config.Config,
    io: std.Io,
    params: ?std.json.Value,
) !ToolResult {
    const p = params orelse return error.MissingParams;
    if (p != .object) return error.MissingParams;
    // Type-check rather than blindly accessing `.string`: a non-string `name`
    // (e.g. {"name": 5}) is an inactive-union access = silent UB in ReleaseFast.
    const name = switch (p.object.get("name") orelse return error.MissingToolName) {
        .string => |s| s,
        else => return error.MissingToolName,
    };
    const args: ?std.json.Value = p.object.get("arguments");

    // Semantic tools need the embedding model; load it lazily on first use so
    // server startup (initialize/tools/list) stays instant.
    if (std.mem.eql(u8, name, "memory_search") or std.mem.eql(u8, name, "memory_store") or std.mem.eql(u8, name, "memory_dream")) {
        if (!embedder.isReady()) embedder.initGlobal(cfg.model_path) catch {};
    }

    if (std.mem.eql(u8, name, "memory_search")) {
        const query = getStr(args, "query") orelse return error.MissingQuery;
        // Clamp attacker-controlled limit to a sane range. Without this, an
        // out-of-i32 or negative value is UB via @intCast (and an overflow in
        // the searcher's `limit * 2`) under ReleaseFast.
        const limit: i32 = @intCast(std.math.clamp(getInt(args, "limit") orelse 5, 1, 100));
        const wing = getStr(args, "wing") orelse blk: {
            if (!std.mem.eql(u8, cfg.default_wing, "default")) break :blk cfg.default_wing;
            break :blk null;
        };
        const mode_s = getStr(args, "mode") orelse "hybrid";
        const mode = searcher.SearchMode.parse(mode_s) orelse .hybrid;
        const as_of = getInt(args, "as_of");
        const detail_s = getStr(args, "detail") orelse "index";
        const full = std.ascii.eqlIgnoreCase(detail_s, "full");
        return toolSearch(allocator, pal, io, query, limit, wing, mode, as_of, full, getBudget(args));
    } else if (std.mem.eql(u8, name, "memory_get")) {
        return toolGet(allocator, pal, args);
    } else if (std.mem.eql(u8, name, "memory_store")) {
        const content = getStr(args, "content") orelse return error.MissingContent;
        const wing = getStr(args, "wing") orelse cfg.default_wing;
        const room = getStr(args, "room") orelse "notes";
        const source = fleet.resolveSource(getStr(args, "source"), "agent");
        const scratch = getBool(args, "scratch") orelse false;
        // Content-hash dedup returns the ORIGINAL drawer id — never stamp a
        // scratch expiry onto a pre-existing durable memory.
        var was_new = true;
        {
            var hash_buf: [64]u8 = undefined;
            if (palace.Palace.contentHashHex(content, &hash_buf)) |hex| {
                was_new = !pal.hasContentHash(hex);
            } else |_| {}
        }
        const id = try miner.storeMemory(pal, content, wing, room, "agent", allocator);
        fleet.setDrawerSource(database, id, source);
        if (scratch and was_new) {
            const ttl = fleet.scratchTtlSeconds();
            fleet.stampScratch(database, id, ttl);
            return .{ .text = try std.fmt.allocPrint(
                allocator,
                "Stored scratch memory #{d} in {s}/{s} (source: {s}; expires in ~{d}h unless memory_promote'd).",
                .{ id, wing, room, source, @divTrunc(ttl, 3600) },
            ) };
        }
        return .{ .text = try std.fmt.allocPrint(allocator, "Stored memory #{d} in {s}/{s} (source: {s}).", .{ id, wing, room, source }) };
    } else if (std.mem.eql(u8, name, "memory_forget")) {
        // The id is required; accept an out-of-range value gracefully (it simply
        // matches nothing) rather than treating it as UB.
        const fid = getInt(args, "id") orelse return error.MissingId;
        const removed = try pal.deleteDrawer(fid);
        const text = if (removed)
            try std.fmt.allocPrint(allocator, "Forgot memory #{d}.", .{fid})
        else
            try std.fmt.allocPrint(allocator, "No memory #{d} found to forget.", .{fid});
        return .{ .text = text };
    } else if (std.mem.eql(u8, name, "memory_wake_up")) {
        const wing = getStr(args, "wing") orelse blk: {
            if (!std.mem.eql(u8, cfg.default_wing, "default")) break :blk cfg.default_wing;
            break :blk null;
        };
        return .{ .text = try wakeup.generateBudgeted(database, wing, getBudget(args), allocator) };
    } else if (std.mem.eql(u8, name, "memory_profile")) {
        const wing_name = getStr(args, "wing") orelse cfg.default_wing;
        const wing_id = pal.getWingId(wing_name) orelse {
            return .{ .text = try std.fmt.allocPrint(allocator, "No wing '{s}' yet. Store a decision or run memxt mine.", .{wing_name}) };
        };
        var text = try profile_mod.renderBrief(database, wing_id, wing_name, allocator);
        // Append active facts for extra context.
        if (facts_mod.listActive(database, wing_id, 15, allocator)) |fl| {
            defer facts_mod.freeFacts(fl, allocator);
            if (fl.len > 0) {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer buf.deinit(allocator);
                try buf.appendSlice(allocator, text);
                allocator.free(text);
                text = ""; // ownership moved
                try buf.appendSlice(allocator, "\n### Active facts\n");
                for (fl) |f| {
                    const line = try std.fmt.allocPrint(allocator, "- {s} —[{s}]→ {s}\n", .{ f.subject, f.predicate, f.object });
                    defer allocator.free(line);
                    try buf.appendSlice(allocator, line);
                }
                return .{ .text = try buf.toOwnedSlice(allocator) };
            }
        } else |_| {}
        return .{ .text = text };
    } else if (std.mem.eql(u8, name, "memory_dream")) {
        var opts = dream_mod.DreamOptions{};
        if (getInt(args, "budget")) |b| opts.hot_budget = b;
        if (args) |a| {
            if (a == .object) {
                if (a.object.get("dry_run")) |v| {
                    opts.dry_run = switch (v) {
                        .bool => |b| b,
                        else => false,
                    };
                }
            }
        }
        const report = try dream_mod.run(database, opts, allocator);
        return .{ .text = try dream_mod.formatReport(report, allocator) };
    } else if (std.mem.eql(u8, name, "memory_stats")) {
        return .{ .text = try pal.stats(allocator) };
    } else if (std.mem.eql(u8, name, "memory_promote")) {
        const pid = getInt(args, "id") orelse return error.MissingId;
        const text = switch (fleet.promote(database, pid)) {
            .promoted => try std.fmt.allocPrint(allocator, "Memory #{d} promoted — expiry cleared, now durable.", .{pid}),
            .already_durable => try std.fmt.allocPrint(allocator, "Memory #{d} is already durable (no expiry set).", .{pid}),
            .not_found => try std.fmt.allocPrint(allocator, "No memory #{d} found to promote.", .{pid}),
        };
        return .{ .text = text };
    }
    return .{ .text = try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{name}) };
}

const INDEX_SNIPPET_CHARS: usize = 120;

// Budget mode: fetch deeper than the plain index so the packer has real
// choice, feed full bodies for the top few and snippets for the rest.
const PACK_FETCH_K: i32 = 20;
const PACK_FULL_BODY_TOP: usize = 5;
const PACK_SNIPPET_CHARS: usize = 240;

fn toolSearch(
    allocator: Allocator,
    pal: *palace.Palace,
    io: std.Io,
    query: []const u8,
    limit: i32,
    wing: ?[]const u8,
    mode: searcher.SearchMode,
    as_of: ?i64,
    full: bool,
    budget_tokens: ?usize,
) !ToolResult {
    var q_vec: []const f32 = &[_]f32{};
    var q_owned = false;
    if (mode != .facts) {
        if (!embedder.isReady()) return .{ .text = try allocator.dupe(u8, "Memory model not loaded; semantic search unavailable.") };
        q_vec = try embedder.embed(query, allocator);
        q_owned = true;
    }
    defer if (q_owned) allocator.free(q_vec);

    const fetch_limit: i32 = if (budget_tokens != null) @max(limit, PACK_FETCH_K) else limit;
    const results = try searcher.search(pal, query, q_vec, .{
        .limit = fetch_limit,
        .wing = wing,
        .mode = mode,
        .as_of = as_of,
    }, allocator, io);
    defer {
        for (results) |r| {
            allocator.free(r.content);
            allocator.free(r.source_path);
            allocator.free(r.wing_name);
            allocator.free(r.room_name);
        }
        allocator.free(results);
    }

    if (results.len == 0) return .{ .text = try allocator.dupe(u8, "No relevant memories found.") };

    if (budget_tokens) |bt| return toolSearchPacked(allocator, results, bt);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (full) {
        const header = try std.fmt.allocPrint(allocator, "Found {d} relevant memor{s}:\n\n", .{
            results.len, if (results.len == 1) "y" else "ies",
        });
        defer allocator.free(header);
        try out.appendSlice(allocator, header);
        for (results, 0..) |r, i| {
            const block = try std.fmt.allocPrint(allocator, "{d}. [#{d} {s}/{s}] {s}\n{s}\n\n", .{
                i + 1, r.drawer_id, r.wing_name, r.room_name, r.source_path, r.content,
            });
            defer allocator.free(block);
            try out.appendSlice(allocator, block);
        }
    } else {
        // Compact index: ids + short snippets. Agent calls memory_get for full bodies.
        const header = try std.fmt.allocPrint(allocator,
            \\Found {d} hit(s) (index). Call memory_get with promising id(s) for full text.
            \\
            \\
        , .{results.len});
        defer allocator.free(header);
        try out.appendSlice(allocator, header);
        for (results, 0..) |r, i| {
            const snip = snippetOf(r.content, INDEX_SNIPPET_CHARS);
            const block = try std.fmt.allocPrint(allocator, "{d}. #{d}  [{s}/{s}]  {s}\n   {s}\n", .{
                i + 1, r.drawer_id, r.wing_name, r.room_name, r.source_path, snip,
            });
            defer allocator.free(block);
            try out.appendSlice(allocator, block);
        }
    }

    const Hit = struct {
        id: i64,
        wing: []const u8,
        room: []const u8,
        source: []const u8,
        score: f64,
        content: []const u8,
        detail: []const u8,
    };
    const hits = try allocator.alloc(Hit, results.len);
    defer allocator.free(hits);
    // Owned snippets for index mode so structured JSON stays self-contained.
    var snip_owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (snip_owned.items) |s| allocator.free(s);
        snip_owned.deinit(allocator);
    }
    for (results, 0..) |r, i| {
        const body: []const u8 = if (full) r.content else blk: {
            const s = try allocator.dupe(u8, snippetOf(r.content, INDEX_SNIPPET_CHARS));
            try snip_owned.append(allocator, s);
            break :blk s;
        };
        hits[i] = .{
            .id = r.drawer_id,
            .wing = r.wing_name,
            .room = r.room_name,
            .source = r.source_path,
            .score = r.score,
            .content = body,
            .detail = if (full) "full" else "index",
        };
    }
    const structured = try std.json.Stringify.valueAlloc(allocator, .{ .results = hits }, .{});
    errdefer allocator.free(structured);

    return .{ .text = try out.toOwnedSlice(allocator), .structured = structured };
}

/// Budget mode: compile the ranked hits into ONE packed markdown brief that
/// fits `budget` tokens (facts first, then bodies, trimmed at line
/// boundaries), instead of the plain index list.
fn toolSearchPacked(allocator: Allocator, results: []const palace.SearchResult, budget: usize) !ToolResult {
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (labels.items) |l| allocator.free(l);
        labels.deinit(allocator);
    }
    var items: std.ArrayListUnmanaged(packer.Item) = .empty;
    defer items.deinit(allocator);

    var body_rank: usize = 0;
    for (results) |r| {
        // Facts surface with source_path "fact" (see searcher.zig) — dense tier.
        if (std.mem.eql(u8, r.source_path, "fact")) {
            try items.append(allocator, .{
                .kind = .fact,
                .text = r.content,
                .drawer_id = if (r.drawer_id > 0) r.drawer_id else null,
            });
            continue;
        }
        const label = try std.fmt.allocPrint(allocator, "[{s}/{s}] {s}", .{ r.wing_name, r.room_name, r.source_path });
        try labels.append(allocator, label);
        const kind: packer.ItemKind = if (body_rank < PACK_FULL_BODY_TOP) .body else .snippet;
        try items.append(allocator, .{
            .kind = kind,
            .text = if (kind == .body) r.content else snippetOf(r.content, PACK_SNIPPET_CHARS),
            .drawer_id = r.drawer_id,
            .label = label,
        });
        body_rank += 1;
    }

    // Reserve a little headroom so header line + brief stay within budget.
    const reserve = @min(budget / 5, 16);
    var pk = try packer.pack(items.items, budget - reserve, allocator);
    defer pk.deinit(allocator);

    const text = try std.fmt.allocPrint(allocator,
        \\Packed brief — budget {d} tokens, ~{d} estimated used, {d}/{d} hits packed. memory_get an id for full text.
        \\
        \\{s}
    , .{ budget, pk.used_tokens, pk.included, pk.total, pk.text });
    errdefer allocator.free(text);

    const structured = try std.json.Stringify.valueAlloc(allocator, .{
        .budget_tokens = budget,
        .estimated_tokens = pk.used_tokens,
        .packed_hits = pk.included,
        .total_hits = pk.total,
        .brief = pk.text,
    }, .{});
    errdefer allocator.free(structured);

    return .{ .text = text, .structured = structured };
}

fn snippetOf(content: []const u8, max_chars: usize) []const u8 {
    // Collapse runs of whitespace into single spaces for denser index lines.
    if (content.len == 0) return "";
    var end = @min(content.len, max_chars);
    // Prefer breaking at a space near the end.
    if (end < content.len) {
        var i = end;
        while (i > max_chars / 2) : (i -= 1) {
            if (content[i] == ' ' or content[i] == '\n') {
                end = i;
                break;
            }
        }
    }
    return content[0..end];
}

fn toolGet(allocator: Allocator, pal: *palace.Palace, args: ?std.json.Value) !ToolResult {
    var ids_buf: [32]i64 = undefined;
    const n = collectIds(args, &ids_buf);
    if (n == 0) return .{ .text = try allocator.dupe(u8, "memory_get requires `id` or `ids` (drawer ids from memory_search).") };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const Hit = struct {
        id: i64,
        wing: []const u8,
        room: []const u8,
        source: []const u8,
        kind: []const u8,
        content: []const u8,
    };
    var hits_list: std.ArrayListUnmanaged(Hit) = .empty;
    defer hits_list.deinit(allocator);
    var owned: std.ArrayListUnmanaged(palace.Palace.DrawerDetail) = .empty;
    defer {
        for (owned.items) |*d| d.deinit(allocator);
        owned.deinit(allocator);
    }

    var found: usize = 0;
    for (ids_buf[0..n]) |id| {
        const row = pal.getDrawer(id, allocator) catch continue;
        const detail = row orelse {
            const miss = try std.fmt.allocPrint(allocator, "(no memory #{d})\n\n", .{id});
            defer allocator.free(miss);
            try out.appendSlice(allocator, miss);
            continue;
        };
        try owned.append(allocator, detail);
        const d = &owned.items[owned.items.len - 1];
        found += 1;
        const block = try std.fmt.allocPrint(allocator, "### #{d} [{s}/{s}] {s}\n{s}\n\n", .{
            d.id, d.wing, d.room, d.source_path, d.content,
        });
        defer allocator.free(block);
        try out.appendSlice(allocator, block);
        try hits_list.append(allocator, .{
            .id = d.id,
            .wing = d.wing,
            .room = d.room,
            .source = d.source_path,
            .kind = d.kind,
            .content = d.content,
        });
    }

    if (found == 0 and out.items.len == 0) {
        return .{ .text = try allocator.dupe(u8, "No memories found for those ids.") };
    }
    if (found == 0) {
        return .{ .text = try out.toOwnedSlice(allocator) };
    }

    const structured = try std.json.Stringify.valueAlloc(allocator, .{ .results = hits_list.items }, .{});
    errdefer allocator.free(structured);
    return .{ .text = try out.toOwnedSlice(allocator), .structured = structured };
}

/// Accept `id` (int) and/or `ids` (array of int). Caps at ids_buf.len.
fn collectIds(args: ?std.json.Value, ids_buf: []i64) usize {
    const a = args orelse return 0;
    if (a != .object) return 0;
    var n: usize = 0;
    if (a.object.get("ids")) |v| {
        if (v == .array) {
            for (v.array.items) |item| {
                if (n >= ids_buf.len) break;
                const id: ?i64 = switch (item) {
                    .integer => |i| i,
                    .float => |f| if (f >= -1.0e18 and f <= 1.0e18) @intFromFloat(f) else null,
                    .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
                    else => null,
                };
                if (id) |i| {
                    ids_buf[n] = i;
                    n += 1;
                }
            }
        }
    }
    if (getInt(args, "id")) |single| {
        // Avoid duplicate if already in list.
        var exists = false;
        for (ids_buf[0..n]) |x| {
            if (x == single) {
                exists = true;
                break;
            }
        }
        if (!exists and n < ids_buf.len) {
            ids_buf[n] = single;
            n += 1;
        }
    }
    return n;
}

// ── Prompts: prompts/get ──

fn handlePromptGet(allocator: Allocator, io: std.Io, id: std.json.Value, params: ?std.json.Value) !void {
    const p = params orelse return sendError(allocator, io, id, -32602, "missing params");
    if (p != .object) return sendError(allocator, io, id, -32602, "missing params");
    const name = switch (p.object.get("name") orelse return sendError(allocator, io, id, -32602, "missing prompt name")) {
        .string => |s| s,
        else => return sendError(allocator, io, id, -32602, "missing prompt name"),
    };
    const args: ?std.json.Value = p.object.get("arguments");

    // Build the user-message text, mirroring the plugin command wording. Any
    // interpolation is escaped safely because the whole result is stringified.
    var description: []const u8 = undefined;
    var text: []u8 = undefined;
    if (std.mem.eql(u8, name, "remember")) {
        const content = getStr(args, "content") orelse "";
        description = "Save something to long-term local memory";
        text = try std.fmt.allocPrint(allocator,
            \\Store the following in long-term memory using the `memory_store` tool, kept verbatim
            \\and concise. If it spans multiple distinct facts, store each as its own memory.
            \\
            \\What to remember:
            \\
            \\{s}
            \\
            \\If no text was given, summarize the most important decision or fact from the current
            \\conversation and store that instead. Confirm what you stored in one line.
        , .{content});
    } else if (std.mem.eql(u8, name, "recall")) {
        const query = getStr(args, "query") orelse "";
        description = "Search long-term local memory and answer from it";
        text = try std.fmt.allocPrint(allocator,
            \\Use progressive disclosure on local memory:
            \\1. `memory_search` with the query (default detail=index — compact hits).
            \\2. `memory_get` with the promising id(s) for full verbatim text.
            \\Answer using what you find; cite drawer ids/sources. If nothing relevant, say so.
            \\
            \\Query:
            \\
            \\{s}
        , .{query});
    } else {
        return sendError(allocator, io, id, -32602, "unknown prompt");
    }
    defer allocator.free(text);

    const out = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = .{
            .description = description,
            .messages = .{
                .{ .role = "user", .content = .{ .@"type" = "text", .text = text } },
            },
        },
    }, .{});
    defer allocator.free(out);
    writeLine(io, out);
}

// ── Resources: resources/read ──

fn handleResourceRead(allocator: Allocator, database: *db.Database, cfg: *const config.Config, io: std.Io, id: std.json.Value, params: ?std.json.Value) !void {
    const p = params orelse return sendError(allocator, io, id, -32602, "missing params");
    if (p != .object) return sendError(allocator, io, id, -32602, "missing params");
    const uri = switch (p.object.get("uri") orelse return sendError(allocator, io, id, -32602, "missing uri")) {
        .string => |s| s,
        else => return sendError(allocator, io, id, -32602, "missing uri"),
    };
    if (!std.mem.eql(u8, uri, WAKEUP_URI)) {
        return sendError(allocator, io, id, -32602, "unknown resource uri");
    }

    const wing: ?[]const u8 = if (!std.mem.eql(u8, cfg.default_wing, "default")) cfg.default_wing else null;
    const brief = try wakeup.generate(database, wing, allocator);
    defer allocator.free(brief);

    const out = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = .{
            .contents = .{
                .{ .uri = WAKEUP_URI, .mimeType = "text/plain", .text = brief },
            },
        },
    }, .{});
    defer allocator.free(out);
    writeLine(io, out);
}

// ── JSON-RPC output helpers ──

/// Send {"jsonrpc","id","result":<raw>} where <raw> is already-valid JSON.
fn sendRawResult(allocator: Allocator, io: std.Io, id: std.json.Value, raw_result: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_result, .{}) catch {
        return sendError(allocator, io, id, -32603, "internal serialization error");
    };
    defer parsed.deinit();
    const out = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = parsed.value,
    }, .{});
    defer allocator.free(out);
    writeLine(io, out);
}

/// Send a tools/call result: always the plain-text content envelope, plus an
/// embedded `structuredContent` object when the tool produced one.
fn sendToolResult(allocator: Allocator, io: std.Io, id: std.json.Value, result: ToolResult) !void {
    if (result.structured) |s| {
        // Embed the pre-serialized JSON as a parsed value so it nests as a real
        // object rather than a quoted string. Fall back to text-only on any
        // parse hiccup so a client still gets a valid response.
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, s, .{}) catch {
            return sendToolText(allocator, io, id, result.text);
        };
        defer parsed.deinit();
        const out = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{
                .content = .{
                    .{ .@"type" = "text", .text = result.text },
                },
                .structuredContent = parsed.value,
                .isError = false,
            },
        }, .{});
        defer allocator.free(out);
        writeLine(io, out);
        return;
    }
    try sendToolText(allocator, io, id, result.text);
}

/// Send a tools/call result wrapping plain text in the MCP content envelope.
fn sendToolText(allocator: Allocator, io: std.Io, id: std.json.Value, text: []const u8) !void {
    const out = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = .{
            .content = .{
                .{ .@"type" = "text", .text = text },
            },
            .isError = false,
        },
    }, .{});
    defer allocator.free(out);
    writeLine(io, out);
}

fn sendError(allocator: Allocator, io: std.Io, id: std.json.Value, code: i32, message: []const u8) !void {
    const out = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = code, .message = message },
    }, .{});
    defer allocator.free(out);
    writeLine(io, out);
}

fn writeLine(io: std.Io, json: []const u8) void {
    const stdout = std.Io.File.stdout();
    _ = stdout.writeStreamingAll(io, json) catch {};
    _ = stdout.writeStreamingAll(io, "\n") catch {};
}

// ── std.json.Value argument accessors ──

/// A protocol version is safe to reflect into hand-built JSON only if it
/// contains nothing that could break out of a JSON string. Versions are short
/// tokens of digits, dots, and dashes.
fn isSafeVersion(v: []const u8) bool {
    if (v.len == 0 or v.len > 32) return false;
    for (v) |ch| {
        if (!std.ascii.isDigit(ch) and ch != '.' and ch != '-') return false;
    }
    return true;
}

fn getStr(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const a = args orelse return null;
    if (a != .object) return null;
    const v = a.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn getBool(args: ?std.json.Value, key: []const u8) ?bool {
    const a = args orelse return null;
    if (a != .object) return null;
    const v = a.object.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

/// Optional `budget_tokens` argument, clamped to a sane positive range.
/// Zero/negative/absurd values fall back to null (no budget mode).
fn getBudget(args: ?std.json.Value) ?usize {
    const bt = getInt(args, "budget_tokens") orelse return null;
    if (bt <= 0) return null;
    return @intCast(@min(bt, 1_000_000));
}

fn getInt(args: ?std.json.Value, key: []const u8) ?i64 {
    const a = args orelse return null;
    if (a != .object) return null;
    const v = a.object.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        // Guard @intFromFloat: NaN (comparisons are false → null) and
        // out-of-range floats are UB to cast directly.
        .float => |f| if (f >= -1.0e18 and f <= 1.0e18) @intFromFloat(f) else null,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}
