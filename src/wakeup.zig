// ═══════════════════════════════════════════════════════════════════
// memxt/wakeup.zig — L0+L1 Wake-Up Context Generator
//
// Generates a compact ~600-900 token context payload from the palace
// for injecting into AI session starts. Compatible with the Python
// mempalace wake-up protocol.
//
//   Layer 0: Identity       (~100 tokens) — ~/.memxt/identity.txt
//   Layer 1: Essential Story (~500-800)   — Top drawers by recency
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;

const MAX_L1_DRAWERS = 15;
const MAX_L1_CHARS: usize = 3200;
const DRAWER_PREVIEW_LEN: usize = 200;

/// Generate the full L0+L1 wake-up context string.
pub fn generate(database: *db.Database, wing_filter: ?[]const u8, allocator: Allocator) ![]u8 {
    // ── Layer 0: Identity ──
    const identity = loadIdentity(allocator);
    defer if (identity.allocated) allocator.free(identity.text);

    var result = try std.fmt.allocPrint(allocator, "## L0 — IDENTITY\n{s}\n\n## L1 — ESSENTIAL STORY\n", .{identity.text});
    errdefer allocator.free(result);

    // ── Layer 1: Essential Story ──
    const sql = if (wing_filter != null)
        \\SELECT d.content, d.source_path, r.name, w.name, d.created_at
        \\FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\JOIN wings w ON w.id = r.wing_id
        \\WHERE w.name = ?
        \\ORDER BY d.created_at DESC
        \\LIMIT ?
    else
        \\SELECT d.content, d.source_path, r.name, w.name, d.created_at
        \\FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\JOIN wings w ON w.id = r.wing_id
        \\ORDER BY d.created_at DESC
        \\LIMIT ?
    ;

    const stmt = database.prepare(sql) orelse {
        const no_palace = try std.fmt.allocPrint(allocator, "{s}No palace found. Run: memxt mine <dir>\n", .{result});
        allocator.free(result);
        return no_palace;
    };
    defer db.finalize(stmt);

    if (wing_filter) |wf| {
        db.bindText(stmt, 1, wf);
        db.bindInt(stmt, 2, @intCast(MAX_L1_DRAWERS));
    } else {
        db.bindInt(stmt, 1, @intCast(MAX_L1_DRAWERS));
    }

    var total_chars: usize = 0;
    var count: usize = 0;

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        if (total_chars >= MAX_L1_CHARS) break;

        const content = db.columnText(stmt, 0) orelse continue;
        const source = db.columnText(stmt, 1) orelse "";
        const room = db.columnText(stmt, 2) orelse "";
        const wing = db.columnText(stmt, 3) orelse "";

        const preview_len = @min(content.len, DRAWER_PREVIEW_LEN);
        const suffix: []const u8 = if (content.len > DRAWER_PREVIEW_LEN) "..." else "";

        const line = try std.fmt.allocPrint(allocator, "- [{s}/{s}] ({s}) {s}{s}\n", .{ wing, room, source, content[0..preview_len], suffix });
        defer allocator.free(line);

        const new_result = try std.fmt.allocPrint(allocator, "{s}{s}", .{ result, line });
        allocator.free(result);
        result = new_result;

        total_chars += preview_len;
        count += 1;
    }

    if (count == 0) {
        const empty = try std.fmt.allocPrint(allocator, "{s}Palace is empty. Run: memxt mine <dir>\n", .{result});
        allocator.free(result);
        return empty;
    }

    const footer = try std.fmt.allocPrint(allocator, "{s}\n({d} moments loaded, ~{d} tokens)\n", .{ result, count, total_chars / 4 });
    allocator.free(result);
    return footer;
}

const IdentityResult = struct {
    text: []const u8,
    allocated: bool,
};

const c_env = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});

fn loadIdentity(allocator: Allocator) IdentityResult {
    const home_ptr = c_env.getenv("HOME");
    if (home_ptr == null) return .{
        .text = "No identity configured. Create ~/.memxt/identity.txt",
        .allocated = false,
    };
    const home = std.mem.span(home_ptr);
    const path = std.fmt.allocPrint(allocator, "{s}/.memxt/identity.txt\x00", .{home}) catch return .{
        .text = "No identity configured. Create ~/.memxt/identity.txt",
        .allocated = false,
    };
    defer allocator.free(path);

    const file = c_env.fopen(path.ptr, "r");
    if (file == null) return .{
        .text = "No identity configured. Create ~/.memxt/identity.txt",
        .allocated = false,
    };
    defer _ = c_env.fclose(file);

    // Read up to 10KB
    const buf = allocator.alloc(u8, 10 * 1024) catch return .{
        .text = "Failed to read identity file.",
        .allocated = false,
    };

    const bytes_read = c_env.fread(buf.ptr, 1, buf.len, file);
    if (bytes_read == 0) {
        allocator.free(buf);
        return .{
            .text = "No identity configured. Create ~/.memxt/identity.txt",
            .allocated = false,
        };
    }

    // Shrink to actual size
    const text = allocator.realloc(buf, bytes_read) catch buf[0..bytes_read];
    return .{ .text = text, .allocated = true };
}
