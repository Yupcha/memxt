// ═══════════════════════════════════════════════════════════════════
// memxt/inspect.zig — Palace health for humans and agents
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const palace_mod = @import("palace.zig");
const facts = @import("facts.zig");
const profile = @import("profile.zig");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sys/stat.h");
});

pub fn render(database: *db.Database, db_path: []const u8, allocator: Allocator) ![]u8 {
    var pal = palace_mod.Palace.init(database, allocator);
    const wing_n = pal.wingCount();
    const drawer_n = pal.drawerCount();

    const room_n = countSql(database, "SELECT COUNT(*) FROM rooms");
    const entity_n = countSql(database, "SELECT COUNT(*) FROM entities");
    const rel_n = countSql(database, "SELECT COUNT(*) FROM relationships");
    const fact_active = facts.countActive(database);
    const fact_closed = facts.countClosed(database);
    const profile_n = profile.countActive(database);
    const vec_n = countSql(database, "SELECT COUNT(*) FROM vec_drawers");
    const quant_n = countSql(database, "SELECT COUNT(*) FROM vec_quant");
    const schema_v = database.schemaVersion();

    const size_mb = fileSizeMb(db_path);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator,
        \\╔══════════════════════════════════════════════════╗
        \\║           🔍  memxt inspect — palace health        ║
        \\╠══════════════════════════════════════════════════╣
        \\║  Database:  {s}
        \\║  Size:      {d:.2} MB
        \\║  Schema:    v{d}
        \\╠══════════════════════════════════════════════════╣
        \\║  Wings:           {d:>8}                           ║
        \\║  Rooms:           {d:>8}                           ║
        \\║  Drawers:         {d:>8}                           ║
        \\║  Vectors (hot f32):{d:>7}                           ║
        \\║  Vectors (quant): {d:>8}  (4-bit TurboQuant-style) ║
        \\║  Facts (active):  {d:>8}                           ║
        \\║  Facts (closed):  {d:>8}  (superseded)            ║
        \\║  Profile entries: {d:>8}                           ║
        \\║  KG entities:     {d:>8}                           ║
        \\║  KG relations:    {d:>8}                           ║
        \\
    , .{
        db_path,
        size_mb,
        schema_v,
        @as(u64, @intCast(@max(0, wing_n))),
        @as(u64, @intCast(@max(0, room_n))),
        @as(u64, @intCast(@max(0, drawer_n))),
        @as(u64, @intCast(@max(0, vec_n))),
        @as(u64, @intCast(@max(0, quant_n))),
        @as(u64, @intCast(@max(0, fact_active))),
        @as(u64, @intCast(@max(0, fact_closed))),
        @as(u64, @intCast(@max(0, profile_n))),
        @as(u64, @intCast(@max(0, entity_n))),
        @as(u64, @intCast(@max(0, rel_n))),
    });
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    // Kind breakdown
    try out.appendSlice(allocator, "╠══════════════════════════════════════════════════╣\n║  Drawers by kind:\n");
    appendKindCounts(database, &out, allocator) catch {};

    // Wings
    try out.appendSlice(allocator, "╠══════════════════════════════════════════════════╣\n║  Wings:\n");
    appendWings(database, &out, allocator) catch {};

    // Usage-learned relevance (retrieval telemetry)
    try out.appendSlice(allocator, "╠══════════════════════════════════════════════════╣\n║  Retrieval utility (usage-learned):\n");
    appendUtility(database, &out, allocator) catch {};

    try out.appendSlice(allocator,
        \\╚══════════════════════════════════════════════════╝
        \\
        \\Tips:
        \\  memxt mine .                 seed from this repo
        \\  memxt adopt                  wire coding agents + mine
        \\  memxt wake-up                preview session brief
        \\  store decisions with room "decisions" for profile L1
        \\
    );

    return out.toOwnedSlice(allocator);
}

fn countSql(database: *db.Database, sql: []const u8) i64 {
    const stmt = database.prepare(sql) orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return 0;
}

fn fileSizeMb(path: []const u8) f64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return 0;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: c.struct_stat = undefined;
    if (c.stat(&buf, &st) != 0) return 0;
    return @as(f64, @floatFromInt(st.st_size)) / (1024.0 * 1024.0);
}

fn appendKindCounts(database: *db.Database, out: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
    const stmt = database.prepare(
        \\SELECT COALESCE(kind, 'unknown'), COUNT(*) FROM drawers GROUP BY kind ORDER BY COUNT(*) DESC
    ) orelse return;
    defer db.finalize(stmt);
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const kind = db.columnText(stmt, 0) orelse "?";
        const n = db.columnInt64(stmt, 1);
        const line = try std.fmt.allocPrint(allocator, "║    {s:<14} {d}\n", .{ kind, n });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
}

/// Short usage summary: top-5 most-fetched drawers plus the count of
/// drawers that keep surfacing in search indexes without ever being opened.
/// Tolerates missing telemetry tables (prepare fails → section stays short).
fn appendUtility(database: *db.Database, out: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
    const top = database.prepare(
        \\SELECT u.drawer_id, u.fetched_n, u.surfaced_n, COALESCE(d.content, '')
        \\FROM drawer_utility u
        \\LEFT JOIN drawers d ON d.id = u.drawer_id
        \\WHERE u.fetched_n > 0
        \\ORDER BY u.fetched_n DESC, u.last_fetched DESC
        \\LIMIT 5
    ) orelse {
        try out.appendSlice(allocator, "║    (no usage telemetry yet)\n");
        return;
    };
    defer db.finalize(top);

    var rows: usize = 0;
    while (db.step(top) == db.c.SQLITE_ROW) : (rows += 1) {
        const id = db.columnInt64(top, 0);
        const fetched = db.columnInt64(top, 1);
        const surfaced = db.columnInt64(top, 2);
        const content = db.columnText(top, 3) orelse "";
        var prev_buf: [28]u8 = undefined;
        const p_len = @min(content.len, prev_buf.len);
        for (content[0..p_len], 0..) |ch, i| {
            prev_buf[i] = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
        }
        const preview = prev_buf[0..p_len];
        const line = try std.fmt.allocPrint(allocator, "║    #{d:<6} fetched {d:>3} / surfaced {d:>4}  {s}\n", .{ id, fetched, surfaced, preview });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    if (rows == 0) try out.appendSlice(allocator, "║    (no drawers fetched yet)\n");

    const never_n = countSql(database, "SELECT COUNT(*) FROM drawer_utility WHERE fetched_n = 0 AND surfaced_n > 0");
    const line = try std.fmt.allocPrint(allocator, "║    surfaced but never fetched: {d} drawer(s)\n", .{@as(u64, @intCast(@max(0, never_n)))});
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
}

fn appendWings(database: *db.Database, out: *std.ArrayListUnmanaged(u8), allocator: Allocator) !void {
    const stmt = database.prepare(
        \\SELECT w.name, COUNT(d.id)
        \\FROM wings w
        \\LEFT JOIN rooms r ON r.wing_id = w.id
        \\LEFT JOIN drawers d ON d.room_id = r.id
        \\GROUP BY w.id
        \\ORDER BY COUNT(d.id) DESC
        \\LIMIT 12
    ) orelse return;
    defer db.finalize(stmt);
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const name = db.columnText(stmt, 0) orelse "?";
        const n = db.columnInt64(stmt, 1);
        const line = try std.fmt.allocPrint(allocator, "║    {s:<20} {d} drawers\n", .{ name, n });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
}
