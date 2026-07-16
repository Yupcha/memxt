// ═══════════════════════════════════════════════════════════════════
// memxt/anchors.zig — Grounded memory: evidence anchors + staleness
//
// An anchor pins a drawer to a file on disk (path + content hash).
// At recall time the anchored files are re-hashed: if any changed or
// vanished, the memory is surfaced as STALE instead of being recalled
// with false confidence. When the miner re-mines a file whose chunk is
// still present, the anchor is re-pointed at the new file hash, so the
// memory becomes fresh again. Verification is cheap and lazy — only
// the hits actually being returned are checked, never the whole palace.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");

const c_stdio = @cImport({
    @cInclude("stdio.h");
});

const Allocator = std.mem.Allocator;

pub const Freshness = enum {
    verified,
    stale,
    unanchored,

    pub fn name(self: Freshness) []const u8 {
        return switch (self) {
            .verified => "verified",
            .stale => "stale",
            .unanchored => "unanchored",
        };
    }
};

/// Create the anchors table. Additive (CREATE TABLE IF NOT EXISTS) — no
/// SCHEMA_VERSION bump, no migration edit; safe to call repeatedly.
pub fn ensureTables(database: *db.Database) void {
    database.exec(
        \\CREATE TABLE IF NOT EXISTS anchors (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  drawer_id INTEGER NOT NULL,
        \\  path TEXT NOT NULL,
        \\  content_hash TEXT NOT NULL,
        \\  line_hint INTEGER,
        \\  created_at INTEGER DEFAULT (strftime('%s','now')),
        \\  UNIQUE(drawer_id, path)
        \\)
    );
    database.exec("CREATE INDEX IF NOT EXISTS idx_anchors_drawer ON anchors(drawer_id)");
    database.exec("CREATE INDEX IF NOT EXISTS idx_anchors_path ON anchors(path)");
}

// ── Capture ──

/// Record (or refresh) an anchor for a drawer. Upserts on (drawer_id, path)
/// so a re-mine of a changed file re-points the anchor at the new hash.
/// Best-effort: anchoring must never fail the store that triggered it.
pub fn recordAnchor(database: *db.Database, drawer_id: i64, path: []const u8, content_hash: []const u8, line_hint: ?i64) void {
    const stmt = database.prepare(
        \\INSERT INTO anchors(drawer_id, path, content_hash, line_hint)
        \\VALUES(?, ?, ?, ?)
        \\ON CONFLICT(drawer_id, path) DO UPDATE SET
        \\  content_hash = excluded.content_hash,
        \\  line_hint = COALESCE(excluded.line_hint, line_hint),
        \\  created_at = strftime('%s','now')
    ) orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, drawer_id);
    db.bindText(stmt, 2, path);
    db.bindText(stmt, 3, content_hash);
    if (line_hint) |lh| {
        db.bindInt64(stmt, 4, lh);
    } else {
        _ = db.c.sqlite3_bind_null(stmt, 4);
    }
    _ = db.step(stmt);
}

/// Refresh the anchor of the drawer that stores this exact chunk (looked up
/// by chunk content hash). Used by the miner when a re-mined file still
/// contains the chunk: the drawer content is still true of the file, so its
/// anchor is re-pointed at the file's current hash — fresh again.
pub fn refreshChunkAnchor(database: *db.Database, chunk_hash: []const u8, path: []const u8, file_hash: []const u8) void {
    const stmt = database.prepare("SELECT id FROM drawers WHERE content_hash = ? LIMIT 1") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, chunk_hash);
    if (db.step(stmt) != db.c.SQLITE_ROW) return;
    recordAnchor(database, db.columnInt64(stmt, 0), path, file_hash, null);
}

// ── Path-token detection (memory_store / fact extraction) ──

pub const PathToken = struct {
    path: []const u8,
    line_hint: ?i64,
};

/// Detect file-path-looking tokens in free text: contain a '/', a real
/// extension on the last component, and only path-safe characters. An
/// optional `:NN` suffix is captured as a line hint. Purely lexical — the
/// caller decides whether the file actually exists. Caller frees via
/// freePathTokens.
pub fn detectPathTokens(content: []const u8, allocator: Allocator) ![]PathToken {
    var out: std.ArrayListUnmanaged(PathToken) = .empty;
    errdefer {
        for (out.items) |t| allocator.free(t.path);
        out.deinit(allocator);
    }

    var it = std.mem.tokenizeAny(u8, content, " \t\n\r\"'`()[]{}<>,;|");
    while (it.next()) |raw| {
        if (out.items.len >= 16) break;
        const trimmed = trimToken(raw);
        const split = splitLineHint(trimmed);
        if (!looksLikePath(split.path)) continue;

        var dup = false;
        for (out.items) |t| {
            if (std.mem.eql(u8, t.path, split.path)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        try out.append(allocator, .{
            .path = try allocator.dupe(u8, split.path),
            .line_hint = split.line,
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn freePathTokens(tokens: []PathToken, allocator: Allocator) void {
    for (tokens) |t| allocator.free(t.path);
    allocator.free(tokens);
}

fn trimToken(raw: []const u8) []const u8 {
    var tok = raw;
    while (tok.len > 0) {
        switch (tok[tok.len - 1]) {
            '.', ',', ';', ':', '!', '?', '*' => tok = tok[0 .. tok.len - 1],
            else => break,
        }
    }
    return tok;
}

fn splitLineHint(tok: []const u8) struct { path: []const u8, line: ?i64 } {
    if (std.mem.lastIndexOfScalar(u8, tok, ':')) |ci| {
        if (ci > 0 and ci + 1 < tok.len) {
            const digits = tok[ci + 1 ..];
            var all_digits = true;
            for (digits) |ch| {
                if (!std.ascii.isDigit(ch)) {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) {
                if (std.fmt.parseInt(i64, digits, 10) catch null) |n| {
                    return .{ .path = tok[0..ci], .line = n };
                }
            }
        }
    }
    return .{ .path = tok, .line = null };
}

fn looksLikePath(tok: []const u8) bool {
    if (tok.len < 3 or tok.len > 240) return false;
    if (std.mem.indexOf(u8, tok, "://") != null) return false;
    if (std.mem.indexOf(u8, tok, "//") != null) return false;
    if (std.mem.indexOfScalar(u8, tok, '/') == null) return false;
    for (tok) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '/' and ch != '.' and ch != '_' and ch != '-') return false;
    }
    // The final component needs a plausible extension (".zig", ".md", …).
    const ext = std.fs.path.extension(std.fs.path.basename(tok));
    if (ext.len < 2 or ext.len > 12) return false;
    for (ext[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) return false;
    }
    return true;
}

/// Detect path tokens in stored text; for every one that exists on disk
/// (relative to cwd, which is the wing root for `memxt` invocations and
/// MCP servers started in the project), record an anchor with the file's
/// current content hash. Returns how many anchors were recorded.
pub fn anchorTextPaths(database: *db.Database, drawer_id: i64, content: []const u8, allocator: Allocator) u32 {
    const tokens = detectPathTokens(content, allocator) catch return 0;
    defer freePathTokens(tokens, allocator);

    var count: u32 = 0;
    for (tokens) |t| {
        var hash_buf: [64]u8 = undefined;
        const hex = hashFileHex(t.path, &hash_buf) orelse continue; // must exist
        recordAnchor(database, drawer_id, t.path, hex, t.line_hint);
        count += 1;
    }
    return count;
}

// ── Verification ──

/// SHA-256 hex of a file's current content — the same hash the palace uses
/// for chunk dedup, so a whole-file anchor written by the miner matches.
/// Returns null when the file is missing or unreadable (=> stale).
/// Uses C stdio so it needs no std.Io handle and is callable from anywhere.
pub fn hashFileHex(path: []const u8, out: *[64]u8) ?[]const u8 {
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len == 0 or path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const f = c_stdio.fopen(path_z[0..path.len :0].ptr, "rb") orelse return null;
    defer _ = c_stdio.fclose(f);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c_stdio.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out[0..], hex[0..]);
    return out[0..];
}

pub const VerifyResult = struct {
    freshness: Freshness = .unanchored,
    /// Anchored paths that changed or vanished since storage. Owned.
    stale_paths: [][]u8 = &.{},

    pub fn deinit(self: *VerifyResult, allocator: Allocator) void {
        for (self.stale_paths) |p| allocator.free(p);
        if (self.stale_paths.len > 0) allocator.free(self.stale_paths);
        self.* = .{};
    }
};

/// Re-hash every file anchored to this drawer. A missing file counts as
/// stale. Cheap: one small SELECT plus one hash per anchored file — call it
/// only for the hits actually being returned. Missing anchors table (older
/// palace) degrades to `unanchored`.
pub fn verifyAnchors(database: *db.Database, drawer_id: i64, allocator: Allocator) !VerifyResult {
    const stmt = database.prepare(
        "SELECT path, content_hash FROM anchors WHERE drawer_id = ?",
    ) orelse return .{};
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, drawer_id);

    var any = false;
    var stale: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (stale.items) |p| allocator.free(p);
        stale.deinit(allocator);
    }

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        any = true;
        const path = db.columnText(stmt, 0) orelse continue;
        const stored = db.columnText(stmt, 1) orelse continue;
        var hash_buf: [64]u8 = undefined;
        const current = hashFileHex(path, &hash_buf);
        if (current != null and std.mem.eql(u8, current.?, stored)) continue;
        try stale.append(allocator, try allocator.dupe(u8, path));
    }

    if (!any) return .{};
    if (stale.items.len == 0) return .{ .freshness = .verified };
    return .{
        .freshness = .stale,
        .stale_paths = try stale.toOwnedSlice(allocator),
    };
}

/// Freshness only, when the stale path list isn't needed (search tagging).
pub fn freshness(database: *db.Database, drawer_id: i64, allocator: Allocator) Freshness {
    var vr = verifyAnchors(database, drawer_id, allocator) catch return .unanchored;
    defer vr.deinit(allocator);
    return vr.freshness;
}

// ── Health report (`memxt anchors`) ──

pub const Report = struct {
    anchors_total: i64 = 0,
    drawers_anchored: i64 = 0,
    verified_count: u32 = 0,
    changed_count: u32 = 0,
    missing_count: u32 = 0,
};

/// Render anchor health for the CLI. With `do_verify`, every anchor is
/// re-hashed (this IS the whole-palace scan — explicit, user-invoked only)
/// and stale paths are listed.
pub fn renderReport(database: *db.Database, wing: ?[]const u8, do_verify: bool, allocator: Allocator) ![]u8 {
    var report = Report{};

    // Counts.
    {
        const sql = if (wing != null)
            \\SELECT COUNT(*), COUNT(DISTINCT a.drawer_id) FROM anchors a
            \\JOIN drawers d ON d.id = a.drawer_id
            \\JOIN rooms r ON r.id = d.room_id
            \\JOIN wings w ON w.id = r.wing_id
            \\WHERE w.name = ?
        else
            "SELECT COUNT(*), COUNT(DISTINCT drawer_id) FROM anchors";
        const stmt = database.prepare(sql) orelse return error.PrepareFailed;
        defer db.finalize(stmt);
        if (wing) |w| db.bindText(stmt, 1, w);
        if (db.step(stmt) == db.c.SQLITE_ROW) {
            report.anchors_total = db.columnInt64(stmt, 0);
            report.drawers_anchored = db.columnInt64(stmt, 1);
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator,
        \\⚓ Anchors — grounded memory{s}{s}
        \\   anchors:          {d}
        \\   anchored drawers: {d}
        \\
    , .{
        if (wing != null) " · wing " else "",
        wing orelse "",
        report.anchors_total,
        report.drawers_anchored,
    });
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    if (do_verify and report.anchors_total > 0) {
        var stale_listed: u32 = 0;
        var stale_lines: std.ArrayListUnmanaged(u8) = .empty;
        defer stale_lines.deinit(allocator);

        const sql = if (wing != null)
            \\SELECT a.path, a.content_hash FROM anchors a
            \\JOIN drawers d ON d.id = a.drawer_id
            \\JOIN rooms r ON r.id = d.room_id
            \\JOIN wings w ON w.id = r.wing_id
            \\WHERE w.name = ?
        else
            "SELECT path, content_hash FROM anchors";
        const stmt = database.prepare(sql) orelse return error.PrepareFailed;
        defer db.finalize(stmt);
        if (wing) |w| db.bindText(stmt, 1, w);

        while (db.step(stmt) == db.c.SQLITE_ROW) {
            const path = db.columnText(stmt, 0) orelse continue;
            const stored = db.columnText(stmt, 1) orelse continue;
            var hash_buf: [64]u8 = undefined;
            const current = hashFileHex(path, &hash_buf);
            if (current == null) {
                report.missing_count += 1;
            } else if (std.mem.eql(u8, current.?, stored)) {
                report.verified_count += 1;
                continue;
            } else {
                report.changed_count += 1;
            }
            if (stale_listed < 10) {
                const line = try std.fmt.allocPrint(allocator, "     - {s}{s}\n", .{
                    path, if (current == null) " (missing)" else "",
                });
                defer allocator.free(line);
                try stale_lines.appendSlice(allocator, line);
                stale_listed += 1;
            }
        }

        const verify_block = try std.fmt.allocPrint(allocator,
            \\   verified: {d}   changed: {d}   missing: {d}
            \\
        , .{ report.verified_count, report.changed_count, report.missing_count });
        defer allocator.free(verify_block);
        try out.appendSlice(allocator, verify_block);

        if (stale_lines.items.len > 0) {
            try out.appendSlice(allocator, "   stale paths:\n");
            try out.appendSlice(allocator, stale_lines.items);
        }
    } else if (do_verify) {
        try out.appendSlice(allocator, "   nothing to verify.\n");
    }

    return out.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════

test "path token detection" {
    const a = std.testing.allocator;
    const toks = try detectPathTokens(
        "We store chunks in src/palace.zig and search in src/searcher.zig:42. " ++
            "See https://example.com/a.zig, `docs/notes.md`. plain words no/ext here, src/palace.zig again",
        a,
    );
    defer freePathTokens(toks, a);

    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqualStrings("src/palace.zig", toks[0].path);
    try std.testing.expectEqual(@as(?i64, null), toks[0].line_hint);
    try std.testing.expectEqualStrings("src/searcher.zig", toks[1].path);
    try std.testing.expectEqual(@as(?i64, 42), toks[1].line_hint);
    try std.testing.expectEqualStrings("docs/notes.md", toks[2].path);
}

test "path token detection rejects non-paths" {
    const a = std.testing.allocator;
    const toks = try detectPathTokens(
        "http://x.io/y.zig a//b.zig plain.txt some/dir noext 1/2 x.y/z",
        a,
    );
    defer freePathTokens(toks, a);
    try std.testing.expectEqual(@as(usize, 0), toks.len);
}

test "hashFileHex matches sha256 of content; missing file is null" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const body = "we use sqlite";
    {
        const f = try tmp.dir.createFile(io, "ground.txt", .{});
        defer f.close(io);
        try f.writePositionalAll(io, body, 0);
    }
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ground.txt", .{tmp.sub_path});
    defer a.free(path);

    var hash_buf: [64]u8 = undefined;
    const got = hashFileHex(path, &hash_buf) orelse return error.HashFailed;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(expected[0..], got);

    var miss_buf: [64]u8 = undefined;
    try std.testing.expect(hashFileHex(".zig-cache/tmp/definitely-not-here.txt", &miss_buf) == null);
}

test "verifyAnchors: verified → stale on edit → fresh after refresh → stale on delete" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(io, "anchored.zig", .{});
        defer f.close(io);
        try f.writePositionalAll(io, "const engine = \"sqlite\";", 0);
    }
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/anchored.zig", .{tmp.sub_path});
    defer a.free(path);

    var database = try db.Database.open(":memory:");
    defer database.close();
    ensureTables(&database);

    // Unanchored drawer.
    {
        var vr = try verifyAnchors(&database, 999, a);
        defer vr.deinit(a);
        try std.testing.expectEqual(Freshness.unanchored, vr.freshness);
    }

    var hash_buf: [64]u8 = undefined;
    const h1 = hashFileHex(path, &hash_buf) orelse return error.HashFailed;
    recordAnchor(&database, 7, path, h1, null);
    {
        var vr = try verifyAnchors(&database, 7, a);
        defer vr.deinit(a);
        try std.testing.expectEqual(Freshness.verified, vr.freshness);
    }

    // Edit the file → stale, and the changed path is reported.
    {
        const f = try tmp.dir.createFile(io, "anchored.zig", .{});
        defer f.close(io);
        try f.writePositionalAll(io, "const engine = \"postgres\"; // switched!", 0);
    }
    {
        var vr = try verifyAnchors(&database, 7, a);
        defer vr.deinit(a);
        try std.testing.expectEqual(Freshness.stale, vr.freshness);
        try std.testing.expectEqual(@as(usize, 1), vr.stale_paths.len);
        try std.testing.expectEqualStrings(path, vr.stale_paths[0]);
    }

    // Miner-style refresh (upsert on drawer_id+path) → fresh again.
    var hash_buf2: [64]u8 = undefined;
    const h2 = hashFileHex(path, &hash_buf2) orelse return error.HashFailed;
    recordAnchor(&database, 7, path, h2, null);
    try std.testing.expectEqual(Freshness.verified, freshness(&database, 7, a));

    // Delete the file → missing counts as stale.
    try tmp.dir.deleteFile(io, "anchored.zig");
    try std.testing.expectEqual(Freshness.stale, freshness(&database, 7, a));
}

test "anchorTextPaths anchors only paths that exist on disk" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile(io, "grounded.zig", .{});
        defer f.close(io);
        try f.writePositionalAll(io, "pub const x = 1;", 0);
    }
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/grounded.zig", .{tmp.sub_path});
    defer a.free(path);

    var database = try db.Database.open(":memory:");
    defer database.close();
    ensureTables(&database);

    const content = try std.fmt.allocPrint(
        a,
        "decision: config parsing moved to {s} (was src/nonexistent-file.zig)",
        .{path},
    );
    defer a.free(content);

    const n = anchorTextPaths(&database, 3, content, a);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(Freshness.verified, freshness(&database, 3, a));

    // Edit the anchored file → the stored memory goes stale.
    {
        const f = try tmp.dir.createFile(io, "grounded.zig", .{});
        defer f.close(io);
        try f.writePositionalAll(io, "pub const x = 2;", 0);
    }
    try std.testing.expectEqual(Freshness.stale, freshness(&database, 3, a));
}
