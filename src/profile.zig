// ═══════════════════════════════════════════════════════════════════
// memxt/profile.zig — Versioned project profile entries
//
// Static-ish facts about a wing (project). Updated when high-confidence
// facts are ingested. Powers memory_profile and wake-up L1 without
// loading the embedding model.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;

pub const Entry = struct {
    id: i64,
    key: []const u8,
    value: []const u8,
    source_fact_id: ?i64,
    valid_from: i64,
};

/// Upsert: close previous active key, insert new value.
pub fn upsertEntry(
    database: *db.Database,
    wing_id: i64,
    key: []const u8,
    value: []const u8,
    source_fact_id: i64,
) !void {
    // Skip if identical active value exists.
    {
        const check = database.prepare(
            \\SELECT id, value FROM profile_entries
            \\WHERE wing_id = ? AND key = ? AND valid_until IS NULL
            \\ORDER BY id DESC LIMIT 1
        ) orelse return error.PrepareFailed;
        defer db.finalize(check);
        db.bindInt64(check, 1, wing_id);
        db.bindText(check, 2, key);
        if (db.step(check) == db.c.SQLITE_ROW) {
            const existing = db.columnText(check, 1) orelse "";
            if (std.mem.eql(u8, existing, value)) return;
            const old_id = db.columnInt64(check, 0);
            const close = database.prepare(
                "UPDATE profile_entries SET valid_until = strftime('%s','now') WHERE id = ?",
            ) orelse return;
            defer db.finalize(close);
            db.bindInt64(close, 1, old_id);
            _ = db.step(close);
        }
    }

    const stmt = database.prepare(
        \\INSERT INTO profile_entries(wing_id, key, value, source_fact_id)
        \\VALUES(?, ?, ?, ?)
    ) orelse return error.PrepareFailed;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, wing_id);
    db.bindText(stmt, 2, key);
    db.bindText(stmt, 3, value);
    db.bindInt64(stmt, 4, source_fact_id);
    if (db.step(stmt) != db.c.SQLITE_DONE) return error.InsertFailed;
}

pub fn listActive(database: *db.Database, wing_id: i64, limit: i32, allocator: Allocator) ![]Entry {
    const stmt = database.prepare(
        \\SELECT id, key, value, source_fact_id, valid_from
        \\FROM profile_entries
        \\WHERE wing_id = ? AND valid_until IS NULL
        \\ORDER BY id DESC
        \\LIMIT ?
    ) orelse return error.PrepareFailed;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, wing_id);
    db.bindInt(stmt, 2, limit);

    var list: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (list.items) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        list.deinit(allocator);
    }

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        var src: ?i64 = null;
        if (db.c.sqlite3_column_type(stmt, 3) != db.c.SQLITE_NULL) {
            src = db.columnInt64(stmt, 3);
        }
        try list.append(allocator, .{
            .id = db.columnInt64(stmt, 0),
            .key = try allocator.dupe(u8, db.columnText(stmt, 1) orelse ""),
            .value = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
            .source_fact_id = src,
            .valid_from = db.columnInt64(stmt, 4),
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeEntries(items: []Entry, allocator: Allocator) void {
    for (items) |e| {
        allocator.free(e.key);
        allocator.free(e.value);
    }
    allocator.free(items);
}

pub fn countActive(database: *db.Database) i64 {
    const stmt = database.prepare("SELECT COUNT(*) FROM profile_entries WHERE valid_until IS NULL") orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return 0;
}

/// Render a human-readable profile brief for a wing (no embedding model).
pub fn renderBrief(
    database: *db.Database,
    wing_id: i64,
    wing_name: []const u8,
    allocator: Allocator,
) ![]u8 {
    const entries = try listActive(database, wing_id, 20, allocator);
    defer freeEntries(entries, allocator);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "## Project profile (");
    try out.appendSlice(allocator, wing_name);
    try out.appendSlice(allocator, ")\n");

    if (entries.len == 0) {
        try out.appendSlice(allocator, "(no profile facts yet — store decisions with room \"decisions\")\n");
        return out.toOwnedSlice(allocator);
    }

    for (entries) |e| {
        const line = try std.fmt.allocPrint(allocator, "- **{s}**: {s}\n", .{ displayKey(e.key), e.value });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

/// The heuristic extractor stores keys like "Decision.is" (subject + copula).
/// The copula reads as noise in a rendered brief ("**Decision.is**: we chose…"),
/// so trim it for display only — the stored key is untouched.
fn displayKey(key: []const u8) []const u8 {
    const copulas = [_][]const u8{ ".is", ".are", ".was", ".were" };
    for (copulas) |suffix| {
        if (std.mem.endsWith(u8, key, suffix)) return key[0 .. key.len - suffix.len];
    }
    return key;
}
