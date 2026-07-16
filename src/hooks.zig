// ═══════════════════════════════════════════════════════════════════
// memxt/hooks.zig — Claude Code hook protocol (real, 2026)
//
// Reads the hook event JSON on stdin, performs a side effect, and writes
// the documented JSON response on stdout. Events that matter for memory:
//
//   SessionStart  → inject the wake-up brief into the session's context
//                   (additionalContext). Fires again after compaction with
//                   source="compact", so saved context comes right back.
//   PreCompact    → context is about to be summarized away. Read the live
//                   transcript and SAVE the recent tail as a memory so it
//                   survives — genuine auto-save, not a nag.
//   Stop          → session turn ended. Autosave transcript tail (verbatim,
//                   local MiniLM embed only — no cloud LLM compression).
//                   Content-hash dedup avoids flooding the palace.
//
// Deliberately NOT PostToolUse-every-call: that is claude-mem's model and
// needs an AI compressor. We keep zero-network memory ops and denser stores.
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

// Cap how much recent conversation we save (PreCompact keeps more; Stop less).
const MAX_SAVE_CHARS: usize = 6000;
const MAX_STOP_SAVE_CHARS: usize = 3500;
const MAX_TRANSCRIPT_BYTES: usize = 4 * 1024 * 1024;
const MIN_SAVE_CHARS: usize = 80;

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
        try handleSessionStart(database, cfg, allocator);
    } else if (isEvent(event, "PreCompact", "precompact")) {
        handleTranscriptSave(database, cfg, root, allocator, .{
            .source = "precompact-autosave",
            .max_chars = MAX_SAVE_CHARS,
            .min_chars = 40,
            .pin_decisions = true,
        });
        writeStdout("{}\n"); // don't block compaction
    } else if (isEvent(event, "Stop", "stop") or isEvent(event, "SessionEnd", "session-end")) {
        // Autosave without cloud LLM: verbatim tail + local embed. Hash-dedup
        // inside insertDrawer means repeated Stop on the same tail is free.
        handleTranscriptSave(database, cfg, root, allocator, .{
            .source = "session-stop",
            .max_chars = MAX_STOP_SAVE_CHARS,
            .min_chars = MIN_SAVE_CHARS,
            .pin_decisions = true,
        });
        writeStdout("{}\n");
    } else {
        writeStdout("{}\n");
    }
}

fn handleSessionStart(database: *db.Database, cfg: *const config.Config, allocator: Allocator) !void {
    // Scope the brief to the project-derived default wing so sessions don't
    // blend unrelated projects. Fall back to all wings only when still "default".
    const wing: ?[]const u8 = if (!std.mem.eql(u8, cfg.default_wing, "default"))
        cfg.default_wing
    else
        null;
    const context = wakeup.generateCached(database, wing, allocator) catch {
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

const SaveOpts = struct {
    source: []const u8,
    max_chars: usize,
    min_chars: usize,
    pin_decisions: bool,
};

fn handleTranscriptSave(
    database: *db.Database,
    cfg: *const config.Config,
    root: std.json.ObjectMap,
    allocator: Allocator,
    opts: SaveOpts,
) void {
    const tpath = strField(root, "transcript_path") orelse return;

    const tail = extractTranscriptTail(tpath, opts.max_chars, allocator) catch return orelse return;
    defer allocator.free(tail);
    if (tail.len < opts.min_chars) return;

    // Local MiniLM only — never call a cloud LLM to "compress" the session.
    embedder.initGlobal(cfg.model_path) catch {};

    var pal = palace.Palace.init(database, allocator);
    // Episodic: room=sessions → kind=episode; storeMemory also runs heuristic
    // fact extract. Content-hash dedup skips identical tails.
    _ = miner.storeMemory(&pal, tail, cfg.default_wing, "sessions", opts.source, allocator) catch return;

    if (!opts.pin_decisions) return;
    if (looksLikeDecision(tail)) {
        const snippet_len = @min(tail.len, 800);
        const snippet = tail[tail.len - snippet_len ..];
        const src_tag = if (std.mem.eql(u8, opts.source, "session-stop"))
            "stop-decision"
        else
            "precompact-decision";
        _ = miner.storeMemory(&pal, snippet, cfg.default_wing, "decisions", src_tag, allocator) catch {};
    }
}

fn looksLikeDecision(tail: []const u8) bool {
    const needles = [_][]const u8{
        "we use ",   "We use ",
        "we chose ", "We chose ",
        "don't use ", "do not use ",
        "prefer ",   "decided to ",
        "going with ", "will use ",
    };
    for (needles) |n| {
        if (std.mem.indexOf(u8, tail, n) != null) return true;
    }
    return false;
}

// ── Transcript extraction ──

/// Read the JSONL transcript and return the most recent ~max_chars of
/// human-readable conversation text (user prompts + assistant text blocks),
/// oldest-to-newest. Caller owns the result. Tool calls/results are skipped
/// so episodes stay signal-dense without an LLM compressor.
fn extractTranscriptTail(path: []const u8, max_chars: usize, allocator: Allocator) !?[]u8 {
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
    const start = if (pieces.items.len > max_chars) pieces.items.len - max_chars else 0;
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
