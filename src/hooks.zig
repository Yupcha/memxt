// ═══════════════════════════════════════════════════════════════════
// memxt/hooks.zig — Claude Code hook protocol (real, 2026)
//
// Reads the hook event JSON on stdin, performs a side effect, and writes
// the documented JSON response on stdout. Two events matter for memory:
//
//   SessionStart  → inject the wake-up brief into the session's context
//                   (additionalContext). Fires again after compaction with
//                   source="compact", so saved context comes right back.
//   PreCompact    → context is about to be summarized away. Read the live
//                   transcript and SAVE the recent tail as a memory so it
//                   survives — genuine auto-save, not a nag.
//
// We accept both the real Claude Code field (`hook_event_name`) and the
// legacy `hook` field, and match event names case/spelling-liberally.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const palace = @import("palace.zig");
const miner = @import("miner.zig");
const embedder = @import("embedder.zig");
const wakeup = @import("wakeup.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

// POSIX read/write via libc — identical on macOS and Linux, and avoids the
// macOS-only __stdinp/__stdoutp symbols that BSD libc uses.
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});

const STDIN_FD: c_int = 0;
const STDOUT_FD: c_int = 1;

// Cap how much recent conversation we save before compaction.
const MAX_SAVE_CHARS: usize = 6000;
const MAX_TRANSCRIPT_BYTES: usize = 4 * 1024 * 1024;

pub fn processHook(database: *db.Database, cfg: *const config.Config, allocator: Allocator) !void {
    var input_buf: [1024 * 1024]u8 = undefined;
    const nread = c.read(STDIN_FD, &input_buf, input_buf.len);
    if (nread <= 0) {
        writeStdout("{}\n");
        return;
    }
    const input = input_buf[0..@intCast(nread)];

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
        writeStdout("{}\n");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        writeStdout("{}\n");
        return;
    }
    const root = parsed.value.object;

    const event = eventName(root);

    if (isEvent(event, "SessionStart", "session-start")) {
        try handleSessionStart(database, allocator);
    } else if (isEvent(event, "PreCompact", "precompact")) {
        handlePreCompact(database, cfg, root, allocator);
        writeStdout("{}\n"); // don't block compaction
    } else if (isEvent(event, "Stop", "stop")) {
        // Saving on every Stop is noisy; we rely on PreCompact + the agent
        // calling memory_store. Continue silently.
        writeStdout("{}\n");
    } else {
        writeStdout("{}\n");
    }
}

fn handleSessionStart(database: *db.Database, allocator: Allocator) !void {
    const context = wakeup.generate(database, null, allocator) catch {
        writeStdout("{}\n");
        return;
    };
    defer allocator.free(context);

    const escaped = try jsonEscape(context, allocator);
    defer allocator.free(escaped);

    // Inject via the documented SessionStart channel.
    const response = try std.fmt.allocPrint(
        allocator,
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"{s}\"}}}}\n",
        .{escaped},
    );
    defer allocator.free(response);
    writeStdout(response);
}

fn handlePreCompact(database: *db.Database, cfg: *const config.Config, root: std.json.ObjectMap, allocator: Allocator) void {
    const tpath = strField(root, "transcript_path") orelse return;

    const tail = extractTranscriptTail(tpath, allocator) catch return orelse return;
    defer allocator.free(tail);
    if (tail.len < 40) return; // nothing worth saving

    // Embeddings make the saved tail semantically searchable later. Load the
    // model lazily here (PreCompact is rare) so SessionStart stays instant.
    embedder.initGlobal(cfg.model_path) catch {};

    var pal = palace.Palace.init(database, allocator);
    _ = miner.storeMemory(&pal, tail, cfg.default_wing, "sessions", "precompact-autosave", allocator) catch return;
}

// ── Transcript extraction ──

/// Read the JSONL transcript and return the most recent ~MAX_SAVE_CHARS of
/// human-readable conversation text (user prompts + assistant text blocks),
/// oldest-to-newest. Caller owns the result.
fn extractTranscriptTail(path: []const u8, allocator: Allocator) !?[]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const file = c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = c.fclose(file);

    // Read up to a cap; transcripts grow but the tail is what matters.
    const buf = try allocator.alloc(u8, MAX_TRANSCRIPT_BYTES);
    defer allocator.free(buf);
    const got = c.fread(buf.ptr, 1, buf.len, file);
    if (got == 0) return null;
    const data = buf[0..got];

    var pieces: std.ArrayListUnmanaged(u8) = .empty;
    defer pieces.deinit(allocator);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        var lp = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer lp.deinit();
        if (lp.value != .object) continue;
        const obj = lp.value.object;

        const role = roleOf(obj) orelse continue;
        const msg = obj.get("message") orelse continue;
        if (msg != .object) continue;
        const content = msg.object.get("content") orelse continue;

        var text_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer text_buf.deinit(allocator);
        collectText(content, &text_buf, allocator);
        if (text_buf.items.len == 0) continue;

        const header = if (std.mem.eql(u8, role, "user")) "User: " else "Assistant: ";
        pieces.appendSlice(allocator, header) catch {};
        pieces.appendSlice(allocator, text_buf.items) catch {};
        pieces.appendSlice(allocator, "\n\n") catch {};
    }

    if (pieces.items.len == 0) return null;

    // Keep only the tail.
    const start = if (pieces.items.len > MAX_SAVE_CHARS) pieces.items.len - MAX_SAVE_CHARS else 0;
    return try allocator.dupe(u8, pieces.items[start..]);
}

fn roleOf(obj: std.json.ObjectMap) ?[]const u8 {
    // Prefer top-level "type" (user/assistant); fall back to message.role.
    if (obj.get("type")) |t| {
        if (t == .string and (std.mem.eql(u8, t.string, "user") or std.mem.eql(u8, t.string, "assistant")))
            return t.string;
    }
    if (obj.get("message")) |m| {
        if (m == .object) {
            if (m.object.get("role")) |r| {
                if (r == .string) return r.string;
            }
        }
    }
    return null;
}

/// Append plain text from a message `content`, which may be a bare string or
/// an array of blocks. Only text-bearing blocks are collected (tool calls and
/// tool results are skipped to keep saved memories signal-dense).
fn collectText(content: std.json.Value, out: *std.ArrayListUnmanaged(u8), allocator: Allocator) void {
    switch (content) {
        .string => |s| out.appendSlice(allocator, s) catch {},
        .array => |arr| {
            for (arr.items) |block| {
                if (block != .object) continue;
                const btype = block.object.get("type") orelse continue;
                if (btype != .string or !std.mem.eql(u8, btype.string, "text")) continue;
                if (block.object.get("text")) |txt| {
                    if (txt == .string) {
                        out.appendSlice(allocator, txt.string) catch {};
                        out.appendSlice(allocator, " ") catch {};
                    }
                }
            }
        },
        else => {},
    }
}

// ── Event helpers ──

fn eventName(root: std.json.ObjectMap) []const u8 {
    if (strField(root, "hook_event_name")) |n| return n;
    if (strField(root, "hook")) |n| return n;
    return "unknown";
}

fn isEvent(event: []const u8, canonical: []const u8, legacy: []const u8) bool {
    return std.ascii.eqlIgnoreCase(event, canonical) or std.ascii.eqlIgnoreCase(event, legacy);
}

fn strField(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = root.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ── Output ──

fn writeStdout(msg: []const u8) void {
    _ = c.write(STDOUT_FD, msg.ptr, msg.len);
}

fn jsonEscape(text: []const u8, allocator: Allocator) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    for (text) |byte| {
        switch (byte) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (byte < 0x20) {
                    var b: [6]u8 = undefined;
                    const s = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{byte}) catch continue;
                    try result.appendSlice(allocator, s);
                } else {
                    try result.append(allocator, byte);
                }
            },
        }
    }
    return result.toOwnedSlice(allocator);
}
