// ═══════════════════════════════════════════════════════════════════
// memxt/mcp.zig — Model Context Protocol server (stdio JSON-RPC)
//
// Exposes the memory palace to any MCP-capable agent (Claude Code, Cursor,
// Zed, …) over newline-delimited JSON-RPC on stdin/stdout. Five real tools:
//
//   memory_search   — semantic recall across everything mined/stored
//   memory_store    — persist a decision / snippet / fact as a memory
//   memory_forget   — delete a memory by its drawer id
//   memory_wake_up  — load the compact session-start context
//   memory_stats    — palace statistics
//
// Plus two prompts (remember / recall) and one resource (the wake-up brief),
// so the slash commands are portable to any MCP client, not just Claude Code.
//
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
    \\      "description": "Semantic search across the local memory palace (mined code, decisions, notes, past sessions). Use this BEFORE answering questions about prior work, past decisions, or anything that might already be remembered. Returns the most relevant stored memories with their source.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "query": { "type": "string", "description": "What to recall, in natural language." },
    \\          "limit": { "type": "integer", "description": "Max results (default 5).", "default": 5 }
    \\        },
    \\        "required": ["query"]
    \\      }
    \\    },
    \\    {
    \\      "name": "memory_store",
    \\      "description": "Persist an important memory for future sessions: a decision and its rationale, a key code snippet, a constraint, a fact about the project or user. Store anything you'd want to remember next time. Content is kept verbatim.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "content": { "type": "string", "description": "The exact text to remember." },
    \\          "wing": { "type": "string", "description": "Project/domain bucket (default: current project)." },
    \\          "room": { "type": "string", "description": "Topic within the wing (default: notes)." }
    \\        },
    \\        "required": ["content"]
    \\      }
    \\    },
    \\    {
    \\      "name": "memory_wake_up",
    \\      "description": "Load the compact wake-up context (identity + most relevant recent memories, ~600-900 tokens). Call at the start of a session to recover continuity.",
    \\      "inputSchema": {
    \\        "type": "object",
    \\        "properties": {
    \\          "wing": { "type": "string", "description": "Limit to one project/domain (optional)." }
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
    \\      "name": "memory_stats",
    \\      "description": "Report palace statistics: how many wings, rooms, drawers, and entities are stored.",
    \\      "inputSchema": { "type": "object", "properties": {} }
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
    \\      "description": "Compact session-start context: identity + most relevant recent memories (~600-900 tokens).",
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
        try handleResourceRead(allocator, database, io, id, req.params);
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
    if (std.mem.eql(u8, name, "memory_search") or std.mem.eql(u8, name, "memory_store")) {
        if (!embedder.isReady()) embedder.initGlobal(cfg.model_path) catch {};
    }

    if (std.mem.eql(u8, name, "memory_search")) {
        const query = getStr(args, "query") orelse return error.MissingQuery;
        // Clamp attacker-controlled limit to a sane range. Without this, an
        // out-of-i32 or negative value is UB via @intCast (and an overflow in
        // the searcher's `limit * 2`) under ReleaseFast.
        const limit: i32 = @intCast(std.math.clamp(getInt(args, "limit") orelse 5, 1, 100));
        return toolSearch(allocator, pal, io, query, limit);
    } else if (std.mem.eql(u8, name, "memory_store")) {
        const content = getStr(args, "content") orelse return error.MissingContent;
        const wing = getStr(args, "wing") orelse cfg.default_wing;
        const room = getStr(args, "room") orelse "notes";
        const id = try miner.storeMemory(pal, content, wing, room, "agent", allocator);
        return .{ .text = try std.fmt.allocPrint(allocator, "Stored memory #{d} in {s}/{s}.", .{ id, wing, room }) };
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
        const wing = getStr(args, "wing");
        return .{ .text = try wakeup.generate(database, wing, allocator) };
    } else if (std.mem.eql(u8, name, "memory_stats")) {
        return .{ .text = try pal.stats(allocator) };
    }
    return .{ .text = try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{name}) };
}

fn toolSearch(allocator: Allocator, pal: *palace.Palace, io: std.Io, query: []const u8, limit: i32) !ToolResult {
    if (!embedder.isReady()) return .{ .text = try allocator.dupe(u8, "Memory model not loaded; semantic search unavailable.") };

    const q_vec = try embedder.embed(query, allocator);
    defer allocator.free(q_vec);

    const results = try searcher.searchHybrid(pal, query, q_vec, .{ .limit = limit }, allocator, io);
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

    // ── Human-readable text block (unchanged shape for the Claude Code plugin) ──
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

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

    // ── Structured content: {"results":[{id,wing,room,source,score,content}]} ──
    // Each hit carries the stable drawer id (usable directly with memory_forget)
    // plus metadata. Built as a slice of structs borrowing `results`' memory,
    // which is valid until the deferred free above runs.
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
    const structured = try std.json.Stringify.valueAlloc(allocator, .{ .results = hits }, .{});
    errdefer allocator.free(structured);

    return .{ .text = try out.toOwnedSlice(allocator), .structured = structured };
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
            \\Use the `memory_search` tool to recall everything relevant to the query below, then
            \\answer using what you find. Cite the source of each memory you rely on. If memory has
            \\nothing relevant, say so plainly rather than guessing.
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

fn handleResourceRead(allocator: Allocator, database: *db.Database, io: std.Io, id: std.json.Value, params: ?std.json.Value) !void {
    const p = params orelse return sendError(allocator, io, id, -32602, "missing params");
    if (p != .object) return sendError(allocator, io, id, -32602, "missing params");
    const uri = switch (p.object.get("uri") orelse return sendError(allocator, io, id, -32602, "missing uri")) {
        .string => |s| s,
        else => return sendError(allocator, io, id, -32602, "missing uri"),
    };
    if (!std.mem.eql(u8, uri, WAKEUP_URI)) {
        return sendError(allocator, io, id, -32602, "unknown resource uri");
    }

    const brief = try wakeup.generate(database, null, allocator);
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
