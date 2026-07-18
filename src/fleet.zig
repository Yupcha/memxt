// ═══════════════════════════════════════════════════════════════════
// memxt/fleet.zig — Multi-agent / fleet readiness
//
// Modern harnesses spawn parallel subagents and background tasks that all
// share one palace DB. This module keeps that shared palace useful:
//
//   • Write attribution — drawers carry a `source` ("claude-code",
//     "subagent:verify-1", "codex"). Explicit param > MEMXT_SOURCE env >
//     caller fallback.
//   • Scratch tier — session-scoped memories stamped with `expires_at`
//     (default 24h, MEMXT_SCRATCH_TTL seconds). The dream cycle purges
//     expired scratch; `memory_promote` clears the expiry to keep one.
//
// Schema changes here are additive ALTER TABLEs guarded by pragma
// table_info — deliberately NOT a SCHEMA_VERSION bump, so palaces move
// freely between fleet and pre-fleet builds.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const palace_mod = @import("palace.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

/// Fallback TTL for scratch memories: 24 hours.
pub const DEFAULT_SCRATCH_TTL_SECS: i64 = 24 * 60 * 60;

/// Additive fleet columns on drawers, guarded by PRAGMA table_info so the
/// call is idempotent and safe on any schema version.
pub fn ensureColumns(database: *db.Database) void {
    if (!database.columnExists("drawers", "source")) {
        database.exec("ALTER TABLE drawers ADD COLUMN source TEXT DEFAULT ''");
    }
    // expires_at ships with schema v3's lifecycle columns; guard anyway so
    // scratch never depends on another migration path having run first.
    if (!database.columnExists("drawers", "expires_at")) {
        database.exec("ALTER TABLE drawers ADD COLUMN expires_at INTEGER");
    }
}

/// Resolve who is writing: explicit tool param > MEMXT_SOURCE env > fallback.
pub fn resolveSource(explicit: ?[]const u8, fallback: []const u8) []const u8 {
    if (explicit) |s| {
        if (s.len > 0) return s;
    }
    if (c.getenv("MEMXT_SOURCE")) |raw| {
        const v = std.mem.span(raw);
        if (v.len > 0) return v;
    }
    return fallback;
}

/// Scratch TTL in seconds: MEMXT_SCRATCH_TTL env (positive integer seconds),
/// else 24h. Garbage or non-positive values fall back to the default.
pub fn scratchTtlSeconds() i64 {
    const raw = c.getenv("MEMXT_SCRATCH_TTL") orelse return DEFAULT_SCRATCH_TTL_SECS;
    const v = std.mem.span(raw);
    const parsed = std.fmt.parseInt(i64, v, 10) catch return DEFAULT_SCRATCH_TTL_SECS;
    if (parsed <= 0) return DEFAULT_SCRATCH_TTL_SECS;
    return parsed;
}

/// Attribute a drawer to a writer. Never overwrites an earlier attribution —
/// on content-hash dedup the store returns the ORIGINAL drawer id, and its
/// original author must keep the credit.
pub fn setDrawerSource(database: *db.Database, drawer_id: i64, source: []const u8) void {
    if (source.len == 0) return;
    const stmt = database.prepare(
        "UPDATE drawers SET source = ? WHERE id = ? AND (source IS NULL OR source = '')",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, source);
    db.bindInt64(stmt, 2, drawer_id);
    _ = db.stepRetryBusy(stmt);
}

/// Mark a drawer as scratch: it expires ttl_secs from now unless promoted.
pub fn stampScratch(database: *db.Database, drawer_id: i64, ttl_secs: i64) void {
    const stmt = database.prepare(
        "UPDATE drawers SET expires_at = strftime('%s','now') + ? WHERE id = ?",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, ttl_secs);
    db.bindInt64(stmt, 2, drawer_id);
    _ = db.stepRetryBusy(stmt);
}

pub const PromoteOutcome = enum { promoted, already_durable, not_found };

/// Make a scratch memory durable by clearing its expiry.
pub fn promote(database: *db.Database, drawer_id: i64) PromoteOutcome {
    if (!database.columnExists("drawers", "expires_at")) return .not_found;
    // Read first so the caller can tell "wasn't scratch" from "doesn't exist".
    {
        const stmt = database.prepare("SELECT expires_at FROM drawers WHERE id = ?") orelse return .not_found;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, drawer_id);
        if (db.step(stmt) != db.c.SQLITE_ROW) return .not_found;
        if (db.c.sqlite3_column_type(stmt, 0) == db.c.SQLITE_NULL) return .already_durable;
    }
    const stmt = database.prepare("UPDATE drawers SET expires_at = NULL WHERE id = ?") orelse return .not_found;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, drawer_id);
    _ = db.stepRetryBusy(stmt);
    return .promoted;
}

/// Delete scratch drawers whose expiry has passed (dream-cycle hook).
/// Uses Palace.deleteDrawer so vec/quant/FTS rows go with the content.
/// Returns the count purged (dry_run only counts).
pub fn purgeExpiredScratch(pal: *palace_mod.Palace, dry_run: bool) u32 {
    const database = pal.database;
    if (!database.columnExists("drawers", "expires_at")) return 0;

    var ids: [4096]i64 = undefined;
    var n: usize = 0;
    {
        const stmt = database.prepare(
            \\SELECT id FROM drawers
            \\WHERE expires_at IS NOT NULL AND expires_at <= strftime('%s','now')
        ) orelse return 0;
        defer db.finalize(stmt);
        while (db.step(stmt) == db.c.SQLITE_ROW and n < ids.len) : (n += 1) {
            ids[n] = db.columnInt64(stmt, 0);
        }
    }

    var purged: u32 = 0;
    for (ids[0..n]) |id| {
        if (!dry_run) {
            _ = pal.deleteDrawer(id) catch continue;
        }
        purged += 1;
    }
    return purged;
}

// ═══════════════════════════════════════════════════════════════════
// Automated Testing Suite
// ═══════════════════════════════════════════════════════════════════

test "ensureColumns adds source additively and is idempotent" {
    var database = try db.Database.open(":memory:");
    defer database.close();
    database.createPalaceSchema();

    ensureColumns(&database);
    try std.testing.expect(database.columnExists("drawers", "source"));
    try std.testing.expect(database.columnExists("drawers", "expires_at"));

    // Second run must be a no-op, not a duplicate-column error.
    ensureColumns(&database);
    try std.testing.expect(database.columnExists("drawers", "source"));
}

test "source resolution: explicit > MEMXT_SOURCE > fallback" {
    _ = c.unsetenv("MEMXT_SOURCE");
    try std.testing.expectEqualStrings("claude-code", resolveSource(null, "claude-code"));

    _ = c.setenv("MEMXT_SOURCE", "codex", 1);
    defer _ = c.unsetenv("MEMXT_SOURCE");
    try std.testing.expectEqualStrings("codex", resolveSource(null, "agent"));
    // Explicit always wins; an empty explicit falls through to the env.
    try std.testing.expectEqualStrings("subagent:verify-1", resolveSource("subagent:verify-1", "agent"));
    try std.testing.expectEqualStrings("codex", resolveSource("", "agent"));
}

test "scratch TTL: default 24h, env override, garbage falls back" {
    _ = c.unsetenv("MEMXT_SCRATCH_TTL");
    try std.testing.expectEqual(DEFAULT_SCRATCH_TTL_SECS, scratchTtlSeconds());

    _ = c.setenv("MEMXT_SCRATCH_TTL", "3600", 1);
    defer _ = c.unsetenv("MEMXT_SCRATCH_TTL");
    try std.testing.expectEqual(@as(i64, 3600), scratchTtlSeconds());

    _ = c.setenv("MEMXT_SCRATCH_TTL", "not-a-number", 1);
    try std.testing.expectEqual(DEFAULT_SCRATCH_TTL_SECS, scratchTtlSeconds());

    _ = c.setenv("MEMXT_SCRATCH_TTL", "-5", 1);
    try std.testing.expectEqual(DEFAULT_SCRATCH_TTL_SECS, scratchTtlSeconds());
}

test "setDrawerSource stamps once and never overwrites earlier attribution" {
    var database = try db.Database.open(":memory:");
    defer database.close();
    database.createPalaceSchema();
    ensureColumns(&database);

    var pal = palace_mod.Palace.init(&database, std.testing.allocator);
    const wing_id = try pal.createWing("fleet-test", "", "project");
    const room_id = try pal.createRoom(wing_id, "notes", "");

    const none = [_]f32{};
    const id = try pal.insertDrawer(room_id, "attributed note", "test", "memory", 0, none[0..]);

    setDrawerSource(&database, id, "subagent:a");
    setDrawerSource(&database, id, "subagent:b"); // dedup path: must NOT steal credit

    const stmt = database.prepare("SELECT source FROM drawers WHERE id = ?") orelse return error.PrepareFailed;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.step(stmt));
    try std.testing.expectEqualStrings("subagent:a", db.columnText(stmt, 0) orelse "");
}

test "scratch expiry: purge deletes expired, keeps live, promote makes durable" {
    var database = try db.Database.open(":memory:");
    defer database.close();
    database.createPalaceSchema();
    ensureColumns(&database);

    var pal = palace_mod.Palace.init(&database, std.testing.allocator);
    const wing_id = try pal.createWing("fleet-test", "", "project");
    const room_id = try pal.createRoom(wing_id, "notes", "");

    const none = [_]f32{};
    const expired_id = try pal.insertDrawer(room_id, "expired scratch note", "test", "memory", 0, none[0..]);
    const live_id = try pal.insertDrawer(room_id, "live scratch note", "test", "memory", 0, none[0..]);
    const promoted_id = try pal.insertDrawer(room_id, "promoted scratch note", "test", "memory", 0, none[0..]);

    stampScratch(&database, expired_id, -10); // already past
    stampScratch(&database, live_id, 3600); // still in the future
    stampScratch(&database, promoted_id, -10); // past, but promoted below

    try std.testing.expectEqual(PromoteOutcome.promoted, promote(&database, promoted_id));
    try std.testing.expectEqual(PromoteOutcome.already_durable, promote(&database, promoted_id));
    try std.testing.expectEqual(PromoteOutcome.not_found, promote(&database, 999_999));

    // Dry-run reports but deletes nothing.
    try std.testing.expectEqual(@as(u32, 1), purgeExpiredScratch(&pal, true));
    try std.testing.expectEqual(@as(i64, 3), pal.drawerCount());

    try std.testing.expectEqual(@as(u32, 1), purgeExpiredScratch(&pal, false));
    try std.testing.expectEqual(@as(i64, 2), pal.drawerCount());

    // Expired gone; live + promoted survive.
    try std.testing.expect((try pal.getDrawer(expired_id, std.testing.allocator)) == null);
    var live = (try pal.getDrawer(live_id, std.testing.allocator)) orelse return error.TestUnexpectedResult;
    live.deinit(std.testing.allocator);
    var kept = (try pal.getDrawer(promoted_id, std.testing.allocator)) orelse return error.TestUnexpectedResult;
    kept.deinit(std.testing.allocator);
}
