// ═══════════════════════════════════════════════════════════════════
// memxt/facts.zig — Semantic facts, heuristic extract, supersession
//
// Facts are atomic claims (subject, predicate, object) with temporal
// validity. They power profiles and contradiction handling without
// rewriting verbatim drawers.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const knowledge = @import("knowledge.zig");
const profile_mod = @import("profile.zig");

const Allocator = std.mem.Allocator;

pub const Fact = struct {
    id: i64,
    wing_id: i64,
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    confidence: f64,
    trust: []const u8,
    source_drawer_id: ?i64,
    valid_from: i64,
    valid_until: ?i64,
};

pub const Extracted = struct {
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    confidence: f64,
};

/// Heuristic fact extraction — no LLM. Best-effort for agent stores / decisions.
pub fn extractFromText(content: []const u8, allocator: Allocator) ![]Extracted {
    var out: std.ArrayListUnmanaged(Extracted) = .empty;
    errdefer {
        for (out.items) |e| {
            allocator.free(e.subject);
            allocator.free(e.predicate);
            allocator.free(e.object);
        }
        out.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        if (out.items.len >= 5) break;
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len < 12 or line.len > 280) continue;
        if (line[0] == '#' or line[0] == '/' or line[0] == '*') continue;

        // KEY: value or KEY = value
        if (std.mem.indexOf(u8, line, ": ")) |colon| {
            if (colon > 2 and colon < 48) {
                const key = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
                const val = std.mem.trim(u8, line[colon + 2 ..], &std.ascii.whitespace);
                if (key.len > 1 and val.len > 1 and !std.mem.startsWith(u8, key, "http")) {
                    try out.append(allocator, .{
                        .subject = try allocator.dupe(u8, key),
                        .predicate = try allocator.dupe(u8, "is"),
                        .object = try allocator.dupe(u8, val),
                        .confidence = 0.85,
                    });
                    continue;
                }
            }
        }

        const lower_buf = try std.ascii.allocLowerString(allocator, line);
        defer allocator.free(lower_buf);

        // Decision / preference patterns
        const patterns = [_]struct { needle: []const u8, pred: []const u8, conf: f64 }{
            .{ .needle = "we use ", .pred = "uses", .conf = 0.9 },
            .{ .needle = "we chose ", .pred = "chose", .conf = 0.92 },
            .{ .needle = "we prefer ", .pred = "prefers", .conf = 0.9 },
            .{ .needle = "prefer ", .pred = "prefers", .conf = 0.8 },
            .{ .needle = "always ", .pred = "always", .conf = 0.75 },
            .{ .needle = "never ", .pred = "never", .conf = 0.8 },
            .{ .needle = "don't use ", .pred = "avoids", .conf = 0.88 },
            .{ .needle = "do not use ", .pred = "avoids", .conf = 0.88 },
            .{ .needle = "because ", .pred = "because", .conf = 0.7 },
        };

        for (patterns) |p| {
            if (std.mem.indexOf(u8, lower_buf, p.needle)) |idx| {
                const rest = line[idx + p.needle.len ..];
                const obj = std.mem.trim(u8, rest, &std.ascii.whitespace);
                if (obj.len < 2) continue;
                // Subject is "project" for team decisions; object is the claim tail.
                try out.append(allocator, .{
                    .subject = try allocator.dupe(u8, "project"),
                    .predicate = try allocator.dupe(u8, p.pred),
                    .object = try allocator.dupe(u8, obj),
                    .confidence = p.conf,
                });
                break;
            }
        }
    }

    // Whole content as single fact if short and nothing extracted (agent store).
    if (out.items.len == 0 and content.len >= 20 and content.len <= 400) {
        if (std.mem.indexOfScalar(u8, content, '\n') == null) {
            try out.append(allocator, .{
                .subject = try allocator.dupe(u8, "memory"),
                .predicate = try allocator.dupe(u8, "states"),
                .object = try allocator.dupe(u8, std.mem.trim(u8, content, &std.ascii.whitespace)),
                .confidence = 0.65,
            });
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn freeExtracted(items: []Extracted, allocator: Allocator) void {
    for (items) |e| {
        allocator.free(e.subject);
        allocator.free(e.predicate);
        allocator.free(e.object);
    }
    allocator.free(items);
}

/// Insert facts for a wing; supersede active facts with same subject+predicate.
/// Returns count inserted. Also updates profile + knowledge graph.
pub fn ingestExtracted(
    database: *db.Database,
    wing_id: i64,
    wing_name: []const u8,
    drawer_id: i64,
    extracted: []const Extracted,
    trust: []const u8,
    allocator: Allocator,
) !u32 {
    _ = wing_name;
    var count: u32 = 0;
    var graph = knowledge.Graph.init(database, allocator);

    for (extracted) |ex| {
        // Close prior active fact with same subject+predicate in this wing.
        const old_id = findActiveFactId(database, wing_id, ex.subject, ex.predicate);
        if (old_id) |oid| {
            // Only supersede if object changed.
            if (activeFactObjectEquals(database, oid, ex.object)) continue;
            closeFact(database, oid);
        }

        const stmt = database.prepare(
            \\INSERT INTO facts(wing_id, subject, predicate, object, confidence, trust, source_drawer_id, supersedes_id)
            \\VALUES(?, ?, ?, ?, ?, ?, ?, ?)
        ) orelse continue;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, wing_id);
        db.bindText(stmt, 2, ex.subject);
        db.bindText(stmt, 3, ex.predicate);
        db.bindText(stmt, 4, ex.object);
        db.bindDouble(stmt, 5, ex.confidence);
        db.bindText(stmt, 6, trust);
        db.bindInt64(stmt, 7, drawer_id);
        if (old_id) |oid| {
            db.bindInt64(stmt, 8, oid);
        } else {
            _ = db.c.sqlite3_bind_null(stmt, 8);
        }
        if (db.step(stmt) != db.c.SQLITE_DONE) continue;
        const fact_id = database.lastInsertRowId();
        count += 1;

        // Graph edge: subject -[predicate]-> object (best-effort).
        graph.addEdge(ex.subject, ex.predicate, ex.object, drawer_id) catch {};

        // High-confidence facts from decisions/agent promote to profile.
        if (ex.confidence >= 0.75 and (std.mem.eql(u8, trust, "user") or std.mem.eql(u8, trust, "agent") or std.mem.eql(u8, trust, "decision"))) {
            const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ ex.subject, ex.predicate });
            defer allocator.free(key);
            profile_mod.upsertEntry(database, wing_id, key, ex.object, fact_id) catch {};
        }
    }
    return count;
}

fn findActiveFactId(database: *db.Database, wing_id: i64, subject: []const u8, predicate: []const u8) ?i64 {
    const stmt = database.prepare(
        \\SELECT id FROM facts
        \\WHERE wing_id = ? AND subject = ? AND predicate = ? AND valid_until IS NULL
        \\ORDER BY id DESC LIMIT 1
    ) orelse return null;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, wing_id);
    db.bindText(stmt, 2, subject);
    db.bindText(stmt, 3, predicate);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return null;
}

fn activeFactObjectEquals(database: *db.Database, fact_id: i64, object: []const u8) bool {
    const stmt = database.prepare("SELECT object FROM facts WHERE id = ?") orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, fact_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return false;
    const obj = db.columnText(stmt, 0) orelse return false;
    return std.mem.eql(u8, obj, object);
}

fn closeFact(database: *db.Database, fact_id: i64) void {
    const stmt = database.prepare(
        "UPDATE facts SET valid_until = strftime('%s','now') WHERE id = ?",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, fact_id);
    _ = db.step(stmt);
}

/// Active facts for a wing (for profile / MCP). Caller frees strings.
pub fn listActive(database: *db.Database, wing_id: i64, limit: i32, allocator: Allocator) ![]Fact {
    const stmt = database.prepare(
        \\SELECT id, wing_id, subject, predicate, object, confidence, trust,
        \\       source_drawer_id, valid_from, valid_until
        \\FROM facts
        \\WHERE wing_id = ? AND valid_until IS NULL
        \\ORDER BY confidence DESC, id DESC
        \\LIMIT ?
    ) orelse return error.PrepareFailed;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, wing_id);
    db.bindInt(stmt, 2, limit);

    var list: std.ArrayListUnmanaged(Fact) = .empty;
    errdefer {
        for (list.items) |f| {
            allocator.free(f.subject);
            allocator.free(f.predicate);
            allocator.free(f.object);
            allocator.free(f.trust);
        }
        list.deinit(allocator);
    }

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        var until: ?i64 = null;
        if (db.c.sqlite3_column_type(stmt, 9) != db.c.SQLITE_NULL) {
            until = db.columnInt64(stmt, 9);
        }
        var src: ?i64 = null;
        if (db.c.sqlite3_column_type(stmt, 7) != db.c.SQLITE_NULL) {
            src = db.columnInt64(stmt, 7);
        }
        try list.append(allocator, .{
            .id = db.columnInt64(stmt, 0),
            .wing_id = db.columnInt64(stmt, 1),
            .subject = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
            .predicate = try allocator.dupe(u8, db.columnText(stmt, 3) orelse ""),
            .object = try allocator.dupe(u8, db.columnText(stmt, 4) orelse ""),
            .confidence = db.columnDouble(stmt, 5),
            .trust = try allocator.dupe(u8, db.columnText(stmt, 6) orelse "agent"),
            .source_drawer_id = src,
            .valid_from = db.columnInt64(stmt, 8),
            .valid_until = until,
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeFacts(items: []Fact, allocator: Allocator) void {
    for (items) |f| {
        allocator.free(f.subject);
        allocator.free(f.predicate);
        allocator.free(f.object);
        allocator.free(f.trust);
    }
    allocator.free(items);
}

pub fn countActive(database: *db.Database) i64 {
    const stmt = database.prepare("SELECT COUNT(*) FROM facts WHERE valid_until IS NULL") orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return 0;
}

pub fn countClosed(database: *db.Database) i64 {
    const stmt = database.prepare("SELECT COUNT(*) FROM facts WHERE valid_until IS NOT NULL") orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return 0;
}

/// Facts that were valid at unix timestamp `as_of` (temporal / as-of query).
pub fn listAsOf(database: *db.Database, wing_id: i64, as_of: i64, limit: i32, allocator: Allocator) ![]Fact {
    const stmt = database.prepare(
        \\SELECT id, wing_id, subject, predicate, object, confidence, trust,
        \\       source_drawer_id, valid_from, valid_until
        \\FROM facts
        \\WHERE wing_id = ?
        \\  AND valid_from <= ?
        \\  AND (valid_until IS NULL OR valid_until > ?)
        \\ORDER BY confidence DESC, id DESC
        \\LIMIT ?
    ) orelse return error.PrepareFailed;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, wing_id);
    db.bindInt64(stmt, 2, as_of);
    db.bindInt64(stmt, 3, as_of);
    db.bindInt(stmt, 4, limit);

    var list: std.ArrayListUnmanaged(Fact) = .empty;
    errdefer {
        for (list.items) |f| {
            allocator.free(f.subject);
            allocator.free(f.predicate);
            allocator.free(f.object);
            allocator.free(f.trust);
        }
        list.deinit(allocator);
    }

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        var until: ?i64 = null;
        if (db.c.sqlite3_column_type(stmt, 9) != db.c.SQLITE_NULL) {
            until = db.columnInt64(stmt, 9);
        }
        var src: ?i64 = null;
        if (db.c.sqlite3_column_type(stmt, 7) != db.c.SQLITE_NULL) {
            src = db.columnInt64(stmt, 7);
        }
        try list.append(allocator, .{
            .id = db.columnInt64(stmt, 0),
            .wing_id = db.columnInt64(stmt, 1),
            .subject = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
            .predicate = try allocator.dupe(u8, db.columnText(stmt, 3) orelse ""),
            .object = try allocator.dupe(u8, db.columnText(stmt, 4) orelse ""),
            .confidence = db.columnDouble(stmt, 5),
            .trust = try allocator.dupe(u8, db.columnText(stmt, 6) orelse "agent"),
            .source_drawer_id = src,
            .valid_from = db.columnInt64(stmt, 8),
            .valid_until = until,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Expire session/episode-class facts past expires_at; close expired rows.
pub fn expireStale(database: *db.Database) u32 {
    // Close facts past expires_at
    database.exec(
        \\UPDATE facts SET valid_until = strftime('%s','now')
        \\WHERE valid_until IS NULL AND expires_at IS NOT NULL AND expires_at < strftime('%s','now')
    );
    return @intCast(@max(0, database.changes()));
}
