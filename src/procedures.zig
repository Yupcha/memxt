// ═══════════════════════════════════════════════════════════════════
// memxt/procedures.zig — Procedural memory ("how we do things here")
//
// A procedure is a repeated, successful shell-command workflow mined
// from session transcripts: run the tests, the deploy dance, the
// release checklist. Commands are normalized (paths/args stripped
// heuristically) so the *shape* of a workflow is recognized across
// sessions; when the same normalized sequence shows up in a second
// session its times_seen counter increments. Established procedures
// (seen ≥ EMIT_MIN_SEEN sessions) can be emitted as Claude Code
// skills via `memxt skills --emit`.
//
// Storage is a single `procedures` table created here with
// CREATE TABLE IF NOT EXISTS — deliberately NOT part of db.zig's
// versioned migrations yet (integration consolidates later).
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;

// POSIX file IO via libc, matching hooks.zig (portable macOS/Linux, no
// dependency on the std.Io event loop inside hook handling).
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
});

/// A sequence must repeat in at least this many distinct sessions before it
/// is considered an established procedure worth emitting as a skill.
pub const EMIT_MIN_SEEN: i64 = 2;

/// Minimum successful commands in a run to count as a sequence.
const MIN_SEQ_STEPS: usize = 2;
/// Cap steps per procedure so one marathon session doesn't create a novel.
const MAX_SEQ_STEPS: usize = 6;
/// Cap tokens kept per normalized command.
const MAX_NORM_TOKENS: usize = 8;
/// Raw step text is capped (first line only) so heredocs stay out of steps.
const MAX_RAW_STEP_CHARS: usize = 300;
/// Same transcript-read cap as hooks.zig.
const MAX_TRANSCRIPT_BYTES: usize = 4 * 1024 * 1024;

pub const Procedure = struct {
    id: i64,
    wing_id: i64,
    wing_name: []const u8,
    name: []const u8,
    when_to_use: []const u8,
    steps_json: []const u8,
    signature: []const u8,
    source: []const u8,
    times_seen: i64,
    first_seen: i64,
    last_seen: i64,
};

/// One step of a procedure as persisted in the `steps` JSON column.
pub const Step = struct {
    cmd: []const u8,
    note: []const u8 = "",
};

// ── Schema ──

/// Create the procedures table if missing. Safe to call repeatedly.
/// NOT wired into SCHEMA_VERSION migrations — additive, IF NOT EXISTS only.
pub fn ensureTables(database: *db.Database) void {
    database.exec(
        \\CREATE TABLE IF NOT EXISTS procedures (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  wing_id INTEGER NOT NULL REFERENCES wings(id) ON DELETE CASCADE,
        \\  name TEXT NOT NULL,
        \\  when_to_use TEXT NOT NULL DEFAULT '',
        \\  steps TEXT NOT NULL DEFAULT '[]',
        \\  signature TEXT NOT NULL,
        \\  source TEXT DEFAULT '',
        \\  times_seen INTEGER NOT NULL DEFAULT 1,
        \\  first_seen INTEGER DEFAULT (strftime('%s','now')),
        \\  last_seen INTEGER DEFAULT (strftime('%s','now')),
        \\  UNIQUE(wing_id, signature)
        \\)
    );
    database.exec("CREATE INDEX IF NOT EXISTS idx_procedures_wing ON procedures(wing_id)");
    database.exec("CREATE INDEX IF NOT EXISTS idx_procedures_seen ON procedures(wing_id, times_seen)");
}

// ── Normalization ──

/// Normalize a shell command for repeat detection. Heuristics:
///   - only the first line matters (heredocs / multiline bodies dropped)
///   - the leading token keeps its basename (./scripts/deploy.sh → deploy.sh)
///   - other path-ish tokens → <path>, pure numbers → <n>, long hex → <hex>
///   - quoted arguments → <str>, --flag=value → --flag=<v>
///   - capped at MAX_NORM_TOKENS tokens
/// Caller owns the result.
pub fn normalizeCommand(cmd: []const u8, allocator: Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const first_line = if (std.mem.indexOfScalar(u8, cmd, '\n')) |nl| cmd[0..nl] else cmd;

    var it = std.mem.tokenizeAny(u8, first_line, " \t");
    var n_tokens: usize = 0;
    var in_quote: u8 = 0; // set while skipping a multi-token quoted argument
    while (it.next()) |tok| {
        if (in_quote != 0) {
            if (tok.len > 0 and tok[tok.len - 1] == in_quote) in_quote = 0;
            continue;
        }
        if (n_tokens >= MAX_NORM_TOKENS) break;
        if (n_tokens > 0) try out.append(allocator, ' ');

        if (tok[0] == '"' or tok[0] == '\'') {
            if (!(tok.len > 1 and tok[tok.len - 1] == tok[0])) in_quote = tok[0];
            try out.appendSlice(allocator, "<str>");
        } else if (std.mem.startsWith(u8, tok, "--") and std.mem.indexOfScalar(u8, tok, '=') != null) {
            const eq = std.mem.indexOfScalar(u8, tok, '=').?;
            try out.appendSlice(allocator, tok[0 .. eq + 1]);
            try out.appendSlice(allocator, "<v>");
        } else if (isPathish(tok)) {
            if (n_tokens == 0) {
                // Keep the program identity: /usr/bin/python3 → python3.
                try out.appendSlice(allocator, basenameOf(tok));
            } else {
                try out.appendSlice(allocator, "<path>");
            }
        } else if (isAllDigits(tok)) {
            try out.appendSlice(allocator, "<n>");
        } else if (isLongHex(tok)) {
            try out.appendSlice(allocator, "<hex>");
        } else {
            try out.appendSlice(allocator, tok);
        }
        n_tokens += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn isPathish(tok: []const u8) bool {
    return std.mem.indexOfScalar(u8, tok, '/') != null or tok[0] == '~';
}

fn basenameOf(tok: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, tok, '/') orelse return tok;
    const base = tok[idx + 1 ..];
    return if (base.len > 0) base else "<path>";
}

fn isAllDigits(tok: []const u8) bool {
    for (tok) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

fn isLongHex(tok: []const u8) bool {
    if (tok.len < 12) return false;
    for (tok) |ch| {
        const hex = std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!hex) return false;
    }
    return true;
}

/// Commands that are pure exploration/noise, never procedure steps.
fn isNoiseCommand(cmd: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\n");
    const head_tok = it.next() orelse return true;
    const head = basenameOf(head_tok);
    const noise = [_][]const u8{
        "ls",    "pwd",  "cd",    "cat",  "echo", "head", "tail",
        "which", "true", "sleep", "grep", "rg",   "find", "open",
    };
    for (noise) |n| {
        if (std.mem.eql(u8, head, n)) return true;
    }
    return false;
}

/// Short heuristic rationale for a step (no LLM).
fn stepNote(cmd: []const u8) []const u8 {
    const pairs = [_]struct { needle: []const u8, note: []const u8 }{
        .{ .needle = "test", .note = "run the tests" },
        .{ .needle = "commit", .note = "commit the changes" },
        .{ .needle = "push", .note = "push to the remote" },
        .{ .needle = "install", .note = "install dependencies" },
        .{ .needle = "deploy", .note = "deploy" },
        .{ .needle = "lint", .note = "check lint" },
        .{ .needle = "fmt", .note = "check formatting" },
        .{ .needle = "build", .note = "build the project" },
    };
    for (pairs) |p| {
        if (std.mem.indexOf(u8, cmd, p.needle) != null) return p.note;
    }
    return "";
}

/// Derive a slug name from the normalized steps (first three non-flag,
/// non-placeholder tokens per step). Capped at 48 chars.
fn makeName(norm_steps: []const []const u8, allocator: Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    outer: for (norm_steps) |step| {
        var it = std.mem.tokenizeAny(u8, step, " ");
        var taken: usize = 0;
        while (it.next()) |tok| {
            if (tok[0] == '-' or tok[0] == '<') break;
            if (out.items.len > 0) try out.append(allocator, '-');
            for (tok) |ch| {
                try out.append(allocator, if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '-');
            }
            taken += 1;
            if (out.items.len >= 48) break :outer;
            if (taken >= 3) break;
        }
    }
    if (out.items.len > 48) out.shrinkRetainingCapacity(48);
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') out.items.len -= 1;
    if (out.items.len == 0) try out.appendSlice(allocator, "procedure");
    return out.toOwnedSlice(allocator);
}

/// First line of a raw command, capped, for display/steps storage.
fn rawStepOf(cmd: []const u8) []const u8 {
    const first_line = if (std.mem.indexOfScalar(u8, cmd, '\n')) |nl| cmd[0..nl] else cmd;
    const trimmed = std.mem.trim(u8, first_line, &std.ascii.whitespace);
    return trimmed[0..@min(trimmed.len, MAX_RAW_STEP_CHARS)];
}

// ── Recording ──

/// Record one successful command run as a procedure sighting. Consecutive
/// duplicate normalized commands collapse (retries). Returns true when a
/// procedure row was inserted or refreshed.
///
/// Dedup semantics: (wing_id, signature) is unique. A sighting from the SAME
/// source (session) only refreshes last_seen; a sighting from a DIFFERENT
/// source increments times_seen — "seen across sessions".
pub fn recordSequence(
    database: *db.Database,
    wing_id: i64,
    raw_cmds: []const []const u8,
    source: []const u8,
    allocator: Allocator,
) !bool {
    // Normalize + collapse consecutive duplicates.
    var norm_list: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (norm_list.items) |n| allocator.free(n);
        norm_list.deinit(allocator);
    }
    var kept_raw: std.ArrayListUnmanaged([]const u8) = .empty;
    defer kept_raw.deinit(allocator);

    for (raw_cmds) |raw| {
        if (norm_list.items.len >= MAX_SEQ_STEPS) break;
        const norm = try normalizeCommand(raw, allocator);
        if (norm.len == 0) {
            allocator.free(norm);
            continue;
        }
        if (norm_list.items.len > 0 and std.mem.eql(u8, norm_list.items[norm_list.items.len - 1], norm)) {
            allocator.free(norm); // retry of the previous command
            continue;
        }
        try norm_list.append(allocator, norm);
        try kept_raw.append(allocator, rawStepOf(raw));
    }
    if (norm_list.items.len < MIN_SEQ_STEPS) return false;

    const signature = try std.mem.join(allocator, " && ", norm_list.items);
    defer allocator.free(signature);

    // Existing procedure for this signature?
    {
        const sel = database.prepare(
            "SELECT id, source FROM procedures WHERE wing_id = ? AND signature = ?",
        ) orelse return error.PrepareFailed;
        defer db.finalize(sel);
        db.bindInt64(sel, 1, wing_id);
        db.bindText(sel, 2, signature);
        if (db.step(sel) == db.c.SQLITE_ROW) {
            const pid = db.columnInt64(sel, 0);
            const prev_source = db.columnText(sel, 1) orelse "";
            if (std.mem.eql(u8, prev_source, source)) {
                // Same session (e.g. Stop fires repeatedly): refresh only.
                const upd = database.prepare(
                    "UPDATE procedures SET last_seen = strftime('%s','now') WHERE id = ?",
                ) orelse return error.PrepareFailed;
                defer db.finalize(upd);
                db.bindInt64(upd, 1, pid);
                _ = db.step(upd);
            } else {
                const upd = database.prepare(
                    \\UPDATE procedures
                    \\SET times_seen = times_seen + 1, last_seen = strftime('%s','now'), source = ?
                    \\WHERE id = ?
                ) orelse return error.PrepareFailed;
                defer db.finalize(upd);
                db.bindText(upd, 1, source);
                db.bindInt64(upd, 2, pid);
                _ = db.step(upd);
            }
            return true;
        }
    }

    // New procedure.
    const steps_arr = try allocator.alloc(Step, kept_raw.items.len);
    defer allocator.free(steps_arr);
    for (kept_raw.items, 0..) |rc, i| steps_arr[i] = .{ .cmd = rc, .note = stepNote(rc) };
    const steps_json = try std.json.Stringify.valueAlloc(allocator, steps_arr, .{});
    defer allocator.free(steps_json);

    const name = try makeName(norm_list.items, allocator);
    defer allocator.free(name);
    const when = try std.fmt.allocPrint(
        allocator,
        "Use when repeating this workflow in the repo: {s}",
        .{signature},
    );
    defer allocator.free(when);

    const stmt = database.prepare(
        \\INSERT INTO procedures(wing_id, name, when_to_use, steps, signature, source)
        \\VALUES(?, ?, ?, ?, ?, ?)
    ) orelse return error.PrepareFailed;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, wing_id);
    db.bindText(stmt, 2, name);
    db.bindText(stmt, 3, when);
    db.bindText(stmt, 4, steps_json);
    db.bindText(stmt, 5, signature);
    db.bindText(stmt, 6, source);
    if (db.step(stmt) != db.c.SQLITE_DONE) return error.InsertFailed;
    return true;
}

// ── Extraction from transcripts ──

/// Mine repeated successful Bash sequences out of a transcript JSONL blob.
/// `source` identifies the session (session_id or transcript path) so a
/// re-run over the same transcript never double-counts. Returns the number
/// of sequences recorded/refreshed.
pub fn mineTranscriptData(
    database: *db.Database,
    wing_id: i64,
    data: []const u8,
    source: []const u8,
    allocator: Allocator,
) !u32 {
    ensureTables(database);

    const Pending = struct { id: []u8, cmd: []u8 };
    var pending: std.ArrayListUnmanaged(Pending) = .empty;
    defer {
        for (pending.items) |p| {
            allocator.free(p.id);
            allocator.free(p.cmd);
        }
        pending.deinit(allocator);
    }
    var run: std.ArrayListUnmanaged([]u8) = .empty; // successful commands, in order
    defer {
        for (run.items) |r| allocator.free(r);
        run.deinit(allocator);
    }
    var recorded: u32 = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        var lp = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer lp.deinit();
        if (lp.value != .object) continue;
        const msg = lp.value.object.get("message") orelse continue;
        if (msg != .object) continue;
        const content = msg.object.get("content") orelse continue;
        if (content != .array) continue;

        for (content.array.items) |block| {
            if (block != .object) continue;
            const btype = blockStr(block.object, "type") orelse continue;

            if (std.mem.eql(u8, btype, "tool_use")) {
                const tool = blockStr(block.object, "name") orelse continue;
                if (!std.mem.eql(u8, tool, "Bash")) continue;
                const use_id = blockStr(block.object, "id") orelse continue;
                const input = block.object.get("input") orelse continue;
                if (input != .object) continue;
                const cmd = blockStr(input.object, "command") orelse continue;
                if (isNoiseCommand(cmd)) continue;
                const id_dup = try allocator.dupe(u8, use_id);
                errdefer allocator.free(id_dup);
                const cmd_dup = try allocator.dupe(u8, cmd);
                errdefer allocator.free(cmd_dup);
                try pending.append(allocator, .{ .id = id_dup, .cmd = cmd_dup });
            } else if (std.mem.eql(u8, btype, "tool_result")) {
                const use_id = blockStr(block.object, "tool_use_id") orelse continue;
                const idx = findPending(pending.items, use_id) orelse continue;
                const entry = pending.orderedRemove(idx);
                allocator.free(entry.id);
                const failed = blk: {
                    const v = block.object.get("is_error") orelse break :blk false;
                    break :blk switch (v) {
                        .bool => |b| b,
                        else => false,
                    };
                };
                if (failed) {
                    allocator.free(entry.cmd);
                    // A failure breaks the streak: flush what succeeded so far.
                    recorded += flushRun(database, wing_id, &run, source, allocator);
                } else {
                    try run.append(allocator, entry.cmd);
                }
            }
        }
    }
    recorded += flushRun(database, wing_id, &run, source, allocator);
    return recorded;
}

fn findPending(items: anytype, use_id: []const u8) ?usize {
    for (items, 0..) |p, i| {
        if (std.mem.eql(u8, p.id, use_id)) return i;
    }
    return null;
}

fn blockStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

/// Record the current run (if long enough) and reset it. Returns 1 if a
/// sequence was recorded, else 0. Best-effort: DB errors drop the run.
fn flushRun(
    database: *db.Database,
    wing_id: i64,
    run: *std.ArrayListUnmanaged([]u8),
    source: []const u8,
    allocator: Allocator,
) u32 {
    defer {
        for (run.items) |r| allocator.free(r);
        run.clearRetainingCapacity();
    }
    if (run.items.len < MIN_SEQ_STEPS) return 0;
    const ok = recordSequence(database, wing_id, run.items, source, allocator) catch false;
    return if (ok) 1 else 0;
}

/// Read a transcript JSONL file (libc, same cap as hooks.zig) and mine it.
pub fn mineTranscriptFile(
    database: *db.Database,
    wing_id: i64,
    path: []const u8,
    source: []const u8,
    allocator: Allocator,
) !u32 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const file = c.fopen(path_z.ptr, "rb") orelse return 0;
    defer _ = c.fclose(file);

    const buf = try allocator.alloc(u8, MAX_TRANSCRIPT_BYTES);
    defer allocator.free(buf);
    const got = c.fread(buf.ptr, 1, buf.len, file);
    if (got == 0) return 0;

    return mineTranscriptData(database, wing_id, buf[0..got], source, allocator);
}

// ── Listing ──

pub const ListOptions = struct {
    wing_id: ?i64 = null,
    query: ?[]const u8 = null,
    min_seen: i64 = 1,
    limit: i32 = 50,
};

/// Procedures ordered by times_seen desc, most recent first. Caller frees
/// via freeProcedures. `query` filters name/signature/when_to_use (substring).
pub fn list(database: *db.Database, opts: ListOptions, allocator: Allocator) ![]Procedure {
    ensureTables(database);

    const stmt = database.prepare(
        \\SELECT p.id, p.wing_id, w.name, p.name, p.when_to_use, p.steps,
        \\       p.signature, p.source, p.times_seen, p.first_seen, p.last_seen
        \\FROM procedures p
        \\JOIN wings w ON w.id = p.wing_id
        \\WHERE p.times_seen >= ?
        \\  AND (? IS NULL OR p.wing_id = ?)
        \\  AND (? IS NULL OR p.name LIKE ? OR p.signature LIKE ? OR p.when_to_use LIKE ?)
        \\ORDER BY p.times_seen DESC, p.last_seen DESC
        \\LIMIT ?
    ) orelse return error.PrepareFailed;
    defer db.finalize(stmt);

    db.bindInt64(stmt, 1, opts.min_seen);
    if (opts.wing_id) |wid| {
        db.bindInt64(stmt, 2, wid);
        db.bindInt64(stmt, 3, wid);
    } else {
        _ = db.c.sqlite3_bind_null(stmt, 2);
        _ = db.c.sqlite3_bind_null(stmt, 3);
    }
    var like_buf: ?[]u8 = null;
    defer if (like_buf) |lb| allocator.free(lb);
    if (opts.query) |q| {
        like_buf = try std.fmt.allocPrint(allocator, "%{s}%", .{q});
        db.bindText(stmt, 4, q);
        db.bindText(stmt, 5, like_buf.?);
        db.bindText(stmt, 6, like_buf.?);
        db.bindText(stmt, 7, like_buf.?);
    } else {
        _ = db.c.sqlite3_bind_null(stmt, 4);
        _ = db.c.sqlite3_bind_null(stmt, 5);
        _ = db.c.sqlite3_bind_null(stmt, 6);
        _ = db.c.sqlite3_bind_null(stmt, 7);
    }
    db.bindInt(stmt, 8, opts.limit);

    var out: std.ArrayListUnmanaged(Procedure) = .empty;
    errdefer {
        for (out.items) |p| freeProcedure(p, allocator);
        out.deinit(allocator);
    }

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        try out.append(allocator, .{
            .id = db.columnInt64(stmt, 0),
            .wing_id = db.columnInt64(stmt, 1),
            .wing_name = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
            .name = try allocator.dupe(u8, db.columnText(stmt, 3) orelse "procedure"),
            .when_to_use = try allocator.dupe(u8, db.columnText(stmt, 4) orelse ""),
            .steps_json = try allocator.dupe(u8, db.columnText(stmt, 5) orelse "[]"),
            .signature = try allocator.dupe(u8, db.columnText(stmt, 6) orelse ""),
            .source = try allocator.dupe(u8, db.columnText(stmt, 7) orelse ""),
            .times_seen = db.columnInt64(stmt, 8),
            .first_seen = db.columnInt64(stmt, 9),
            .last_seen = db.columnInt64(stmt, 10),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn freeProcedure(p: Procedure, allocator: Allocator) void {
    allocator.free(p.wing_name);
    allocator.free(p.name);
    allocator.free(p.when_to_use);
    allocator.free(p.steps_json);
    allocator.free(p.signature);
    allocator.free(p.source);
}

pub fn freeProcedures(items: []Procedure, allocator: Allocator) void {
    for (items) |p| freeProcedure(p, allocator);
    allocator.free(items);
}

pub fn count(database: *db.Database) i64 {
    ensureTables(database);
    const stmt = database.prepare("SELECT COUNT(*) FROM procedures") orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return 0;
}

// ── Rendering ──

/// Render the steps JSON as a numbered list, one step per line, each line
/// prefixed with `indent`. Caller frees.
pub fn renderSteps(steps_json: []const u8, indent: []const u8, allocator: Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, steps_json, .{}) catch {
        return out.toOwnedSlice(allocator);
    };
    defer parsed.deinit();
    if (parsed.value != .array) return out.toOwnedSlice(allocator);

    for (parsed.value.array.items, 0..) |item, i| {
        if (item != .object) continue;
        const cmd = blockStr(item.object, "cmd") orelse continue;
        const note = blockStr(item.object, "note") orelse "";
        const line = try std.fmt.allocPrint(allocator, "{s}{d}. `{s}`{s}{s}\n", .{
            indent, i + 1, cmd,
            if (note.len > 0) " — " else "",
            note,
        });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

/// Render a Claude Code SKILL.md for one procedure (YAML frontmatter with
/// name + description, when-to-use section, numbered steps). Caller frees.
pub fn renderSkillMd(p: Procedure, name: []const u8, allocator: Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // Single-line, quote-safe description for the YAML frontmatter.
    var desc: std.ArrayListUnmanaged(u8) = .empty;
    defer desc.deinit(allocator);
    const desc_head = try std.fmt.allocPrint(allocator, "Recurring command workflow in this repo (seen {d}x): ", .{p.times_seen});
    defer allocator.free(desc_head);
    try desc.appendSlice(allocator, desc_head);
    for (p.signature) |ch| {
        if (desc.items.len >= 200) break;
        try desc.append(allocator, switch (ch) {
            '"' => '\'',
            '\n', '\r' => ' ',
            else => ch,
        });
    }

    const steps = try renderSteps(p.steps_json, "", allocator);
    defer allocator.free(steps);

    const body = try std.fmt.allocPrint(allocator,
        \\---
        \\name: {s}
        \\description: "{s}"
        \\---
        \\
        \\# {s}
        \\
        \\## When to use
        \\{s}
        \\
        \\## Steps
        \\{s}
        \\_Mined by memxt from session transcripts (source: {s}); seen {d} time(s)._
        \\
    , .{ name, desc.items, name, p.when_to_use, steps, p.source, p.times_seen });
    defer allocator.free(body);
    try out.appendSlice(allocator, body);
    return out.toOwnedSlice(allocator);
}

// ── Skill emission ──

/// Write `<dir>/<name>/SKILL.md` for each procedure. Duplicate names get a
/// `-<id>` suffix so directories never clobber each other. Returns the
/// number of skills written (per-file failures are skipped, best-effort).
pub fn emitSkills(procs: []const Procedure, dir: []const u8, allocator: Allocator) !u32 {
    mkdirAll(dir);

    var used: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (used.items) |u| allocator.free(u);
        used.deinit(allocator);
    }

    var written: u32 = 0;
    for (procs) |p| {
        var name = try allocator.dupe(u8, p.name);
        if (nameTaken(used.items, name)) {
            const unique = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ p.name, p.id });
            allocator.free(name);
            name = unique;
        }
        try used.append(allocator, name); // owned by `used`, freed on exit

        const skill_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
        defer allocator.free(skill_dir);
        mkdirAll(skill_dir);

        const body = try renderSkillMd(p, name, allocator);
        defer allocator.free(body);

        const path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
        defer allocator.free(path);
        writeFileBytes(path, body, allocator) catch continue;
        written += 1;
    }
    return written;
}

fn nameTaken(used: []const []u8, name: []const u8) bool {
    for (used) |u| if (std.mem.eql(u8, u, name)) return true;
    return false;
}

/// mkdir -p, best-effort (EEXIST and races ignored). Mirrors db.zig's
/// ensureParentDirs but creates the leaf directory too.
fn mkdirAll(path: []const u8) void {
    if (path.len == 0) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = c.mkdir(&buf, 0o755);
    }
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.mkdir(&buf, 0o755);
}

fn writeFileBytes(path: []const u8, body: []const u8, allocator: Allocator) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const f = c.fopen(path_z.ptr, "w") orelse return error.FileOpenFailed;
    defer _ = c.fclose(f);
    if (body.len > 0) {
        const n = c.fwrite(body.ptr, 1, body.len, f);
        if (n != body.len) return error.WriteFailed;
    }
}

// ═══════════════════════════════════════════════════════════════════
// Tests — sequence normalization + repeat detection
// ═══════════════════════════════════════════════════════════════════

test "normalizeCommand strips paths, numbers, quoted strings, flag values" {
    const a = std.testing.allocator;
    {
        const n = try normalizeCommand("zig build test", a);
        defer a.free(n);
        try std.testing.expectEqualStrings("zig build test", n);
    }
    {
        const n = try normalizeCommand("cat2 /Users/me/notes.txt", a);
        defer a.free(n);
        try std.testing.expectEqualStrings("cat2 <path>", n);
    }
    {
        const n = try normalizeCommand("sleep2 30", a);
        defer a.free(n);
        try std.testing.expectEqualStrings("sleep2 <n>", n);
    }
    {
        const n = try normalizeCommand("git commit -m \"fix: the bug\"", a);
        defer a.free(n);
        try std.testing.expectEqualStrings("git commit -m <str>", n);
    }
    {
        const n = try normalizeCommand("cmake --build=build/dir target", a);
        defer a.free(n);
        try std.testing.expectEqualStrings("cmake --build=<v> target", n);
    }
    {
        // First token keeps its basename so the program stays identifiable.
        const n = try normalizeCommand("./scripts/deploy.sh prod", a);
        defer a.free(n);
        try std.testing.expectEqualStrings("deploy.sh prod", n);
    }
    {
        // Multiline commands: only the first line matters.
        const n = try normalizeCommand("git add src\ngit commit", a);
        defer a.free(n);
        try std.testing.expectEqualStrings("git add src", n);
    }
}

test "recordSequence collapses retries and dedups by signature" {
    const a = std.testing.allocator;
    var database = try db.Database.open(":memory:");
    defer database.close();
    database.createPalaceSchema();
    ensureTables(&database);
    database.exec("INSERT INTO wings(name) VALUES('testwing')");

    const cmds = [_][]const u8{ "zig build", "zig build", "zig build test" };
    try std.testing.expect(try recordSequence(&database, 1, &cmds, "s1", a));

    const stmt = database.prepare("SELECT signature, times_seen FROM procedures").?;
    defer db.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.step(stmt));
    try std.testing.expectEqualStrings("zig build && zig build test", db.columnText(stmt, 0).?);
    try std.testing.expectEqual(@as(i64, 1), db.columnInt64(stmt, 1));
}

const TEST_TRANSCRIPT =
    \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"zig build"}}]}}
    \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":false}]}}
    \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"zig build test"}}]}}
    \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":false}]}}
;

test "repeat detection: same session never double-counts, second session increments" {
    const a = std.testing.allocator;
    var database = try db.Database.open(":memory:");
    defer database.close();
    database.createPalaceSchema();
    database.exec("INSERT INTO wings(name) VALUES('testwing')");

    _ = try mineTranscriptData(&database, 1, TEST_TRANSCRIPT, "session-A", a);
    _ = try mineTranscriptData(&database, 1, TEST_TRANSCRIPT, "session-A", a);
    try std.testing.expectEqual(@as(i64, 1), maxTimesSeen(&database));

    _ = try mineTranscriptData(&database, 1, TEST_TRANSCRIPT, "session-B", a);
    try std.testing.expectEqual(@as(i64, 2), maxTimesSeen(&database));
    try std.testing.expectEqual(@as(i64, 1), count(&database));
}

test "a failed command breaks the sequence" {
    const a = std.testing.allocator;
    var database = try db.Database.open(":memory:");
    defer database.close();
    database.createPalaceSchema();
    database.exec("INSERT INTO wings(name) VALUES('testwing')");

    const transcript =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"zig build"}}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":false}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"zig build broken"}}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"zig build test"}}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","is_error":false}]}}
    ;
    const n = try mineTranscriptData(&database, 1, transcript, "session-A", a);
    try std.testing.expectEqual(@as(u32, 0), n);
    try std.testing.expectEqual(@as(i64, 0), count(&database));
}

test "renderSkillMd emits YAML frontmatter, when-to-use, and steps" {
    const a = std.testing.allocator;
    const p = Procedure{
        .id = 7,
        .wing_id = 1,
        .wing_name = "testwing",
        .name = "zig-build-zig-build-test",
        .when_to_use = "Use when repeating this workflow in the repo: zig build && zig build test",
        .steps_json = "[{\"cmd\":\"zig build\",\"note\":\"build the project\"},{\"cmd\":\"zig build test\",\"note\":\"run the tests\"}]",
        .signature = "zig build && zig build test",
        .source = "session-A",
        .times_seen = 3,
        .first_seen = 0,
        .last_seen = 0,
    };
    const md = try renderSkillMd(p, p.name, a);
    defer a.free(md);

    try std.testing.expect(std.mem.startsWith(u8, md, "---\nname: zig-build-zig-build-test\n"));
    try std.testing.expect(std.mem.indexOf(u8, md, "description: \"Recurring command workflow in this repo (seen 3x): zig build && zig build test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "## When to use") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "1. `zig build` — build the project") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "2. `zig build test` — run the tests") != null);
}

fn maxTimesSeen(database: *db.Database) i64 {
    const stmt = database.prepare("SELECT COALESCE(MAX(times_seen), 0) FROM procedures") orelse return -1;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return -1;
}
