// ═══════════════════════════════════════════════════════════════════
// memxt/resources.zig — MCP resources (browsable wings and rooms)
//
// Exposes the palace layout as attachable MCP resources with zero
// model cost — plain SQL, no embeddings:
//   memxt://wing/<name>               — all drawers in a wing, by room
//   memxt://wing/<name>/room/<name>   — one room's drawers
// Each read renders a compact markdown index (id, kind, first line) so
// an agent can browse memory the same way it browses files.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const palace = @import("palace.zig");

const Allocator = std.mem.Allocator;

pub const WING_PREFIX = "memxt://wing/";
const ROOM_INFIX = "/room/";

/// Cap per read so a huge palace can't blow up a resource fetch.
const MAX_DRAWERS: i32 = 200;
const FIRST_LINE_CHARS: usize = 100;

/// Render the full resources/list result — the static wake-up brief plus one
/// resource per wing and per room. Returns owned JSON: {"resources":[...]}.
pub fn listJson(pal: *palace.Palace, allocator: Allocator) ![]u8 {
    const Entry = struct {
        uri: []const u8,
        name: []const u8,
        description: []const u8,
        mimeType: []const u8,
    };

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer entries.deinit(allocator);
    var owned: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    try entries.append(allocator, .{
        .uri = "memxt://wakeup",
        .name = "Memory wake-up brief",
        .description = "Compact session-start context: L0 identity + L1 project profile + L2 recent work (~600-1200 tokens).",
        .mimeType = "text/plain",
    });

    const wings = try pal.listWings(allocator);
    defer {
        for (wings) |w| {
            allocator.free(w.name);
            allocator.free(w.description);
            allocator.free(w.wing_type);
        }
        allocator.free(wings);
    }

    for (wings) |w| {
        const wing_uri = try std.fmt.allocPrint(allocator, "{s}{s}", .{ WING_PREFIX, w.name });
        try owned.append(allocator, wing_uri);
        const wing_label = try std.fmt.allocPrint(allocator, "Wing: {s}", .{w.name});
        try owned.append(allocator, wing_label);
        try entries.append(allocator, .{
            .uri = wing_uri,
            .name = wing_label,
            .description = "Markdown index of this wing's drawers (id, kind, first line), grouped by room.",
            .mimeType = "text/markdown",
        });

        const rooms = try pal.listRooms(w.id, allocator);
        defer {
            for (rooms) |r| {
                allocator.free(r.name);
                allocator.free(r.description);
            }
            allocator.free(rooms);
        }
        for (rooms) |r| {
            const room_uri = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ WING_PREFIX, w.name, ROOM_INFIX, r.name });
            try owned.append(allocator, room_uri);
            const room_label = try std.fmt.allocPrint(allocator, "Room: {s}/{s}", .{ w.name, r.name });
            try owned.append(allocator, room_label);
            try entries.append(allocator, .{
                .uri = room_uri,
                .name = room_label,
                .description = "Markdown index of this room's drawers (id, kind, first line).",
                .mimeType = "text/markdown",
            });
        }
    }

    return std.json.Stringify.valueAlloc(allocator, .{ .resources = entries.items }, .{});
}

/// Resolve a memxt://wing/... URI to its markdown index. Returns null when
/// the URI doesn't parse or names a wing/room that doesn't exist (the caller
/// answers with a JSON-RPC "unknown resource" error).
pub fn readMarkdown(pal: *palace.Palace, uri: []const u8, allocator: Allocator) !?[]u8 {
    if (!std.mem.startsWith(u8, uri, WING_PREFIX)) return null;
    const rest = uri[WING_PREFIX.len..];
    if (rest.len == 0) return null;

    var wing_name: []const u8 = rest;
    var room_name: ?[]const u8 = null;
    if (std.mem.indexOf(u8, rest, ROOM_INFIX)) |i| {
        wing_name = rest[0..i];
        const rn = rest[i + ROOM_INFIX.len ..];
        if (wing_name.len == 0 or rn.len == 0) return null;
        room_name = rn;
    }

    const wing_id = pal.getWingId(wing_name) orelse return null;
    if (room_name) |rn| {
        if (pal.getRoomId(wing_id, rn) == null) return null;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "# {s}\n", .{uri});
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    const sql = if (room_name != null)
        \\SELECT d.id, COALESCE(d.kind,'memory'), d.content, r.name
        \\FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\WHERE r.wing_id = ? AND r.name = ?
        \\ORDER BY d.id DESC
        \\LIMIT ?
    else
        \\SELECT d.id, COALESCE(d.kind,'memory'), d.content, r.name
        \\FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\WHERE r.wing_id = ?
        \\ORDER BY r.name, d.id DESC
        \\LIMIT ?
    ;

    const stmt = pal.database.prepare(sql) orelse return error.PrepareFailed;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, wing_id);
    if (room_name) |rn| {
        db.bindText(stmt, 2, rn);
        db.bindInt(stmt, 3, MAX_DRAWERS);
    } else {
        db.bindInt(stmt, 2, MAX_DRAWERS);
    }

    var count: usize = 0;
    // Copy of the last room header written — sqlite reuses its column buffer
    // between step() calls, so we cannot hold on to the returned slice.
    var current_room_buf: [128]u8 = undefined;
    var current_room_len: usize = 0;
    var first_room = true;
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const room = db.columnText(stmt, 3) orelse "";
        // Wing-level reads group drawers under one "## room" header per room.
        if (room_name == null and (first_room or !std.mem.eql(u8, room, current_room_buf[0..current_room_len]))) {
            const hdr = try std.fmt.allocPrint(allocator, "\n## {s}\n", .{room});
            defer allocator.free(hdr);
            try out.appendSlice(allocator, hdr);
            current_room_len = @min(room.len, current_room_buf.len);
            @memcpy(current_room_buf[0..current_room_len], room[0..current_room_len]);
            first_room = false;
        }
        const id = db.columnInt64(stmt, 0);
        const kind = db.columnText(stmt, 1) orelse "memory";
        const content = db.columnText(stmt, 2) orelse "";
        const line = try std.fmt.allocPrint(allocator, "- #{d} [{s}] {s}\n", .{ id, kind, firstLineOf(content) });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        count += 1;
    }

    if (count == 0) try out.appendSlice(allocator, "\n(no drawers)\n");

    return try out.toOwnedSlice(allocator);
}

/// First line of a drawer body, capped for the index (like memory_search's
/// snippets — enough to decide whether to memory_get the full text).
fn firstLineOf(content: []const u8) []const u8 {
    var s = std.mem.trim(u8, content, &std.ascii.whitespace);
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s = std.mem.trimEnd(u8, s[0..nl], &std.ascii.whitespace);
    if (s.len > FIRST_LINE_CHARS) s = s[0..FIRST_LINE_CHARS];
    return s;
}

// ═══════════════════════════════════════════════════════════════════
// Automated Testing Suite
// ═══════════════════════════════════════════════════════════════════

test "resources: list exposes wing and room URIs; read renders drawer index" {
    const allocator = std.testing.allocator;
    var database = try db.Database.open(":memory:");
    defer database.close();
    database.createPalaceSchema();
    var pal = palace.Palace.init(&database, allocator);

    const wing_id = try pal.createWing("testwing", "", "project");
    const room_id = try pal.createRoom(wing_id, "decisions", "");
    _ = try pal.insertDrawerKind(room_id, "We chose SQLite for the palace.\nBecause it is local.", "mcp", "memory", 0, &[_]f32{}, null, null);

    const listing = try listJson(&pal, allocator);
    defer allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "memxt://wakeup") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "memxt://wing/testwing") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "memxt://wing/testwing/room/decisions") != null);

    const wing_md = (try readMarkdown(&pal, "memxt://wing/testwing", allocator)).?;
    defer allocator.free(wing_md);
    try std.testing.expect(std.mem.indexOf(u8, wing_md, "## decisions") != null);
    try std.testing.expect(std.mem.indexOf(u8, wing_md, "We chose SQLite for the palace.") != null);
    // Only the first line appears in the index.
    try std.testing.expect(std.mem.indexOf(u8, wing_md, "Because it is local.") == null);

    const room_md = (try readMarkdown(&pal, "memxt://wing/testwing/room/decisions", allocator)).?;
    defer allocator.free(room_md);
    try std.testing.expect(std.mem.indexOf(u8, room_md, "[decision]") != null);

    try std.testing.expect((try readMarkdown(&pal, "memxt://wing/nope", allocator)) == null);
    try std.testing.expect((try readMarkdown(&pal, "memxt://wing/testwing/room/nope", allocator)) == null);
    try std.testing.expect((try readMarkdown(&pal, "https://example.com", allocator)) == null);
}
