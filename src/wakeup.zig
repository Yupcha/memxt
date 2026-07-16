// ═══════════════════════════════════════════════════════════════════
// memxt/wakeup.zig — L0+L1+L2 Wake-Up Context Generator (v2)
//
// Generates a compact ~600-1200 token context payload from the palace
// for injecting into AI session starts.
//
//   Layer 0: Identity         (~100 tokens) — ~/.memxt/identity.txt
//   Layer 1: Project Profile  (~300-500)    — decisions / profile / conventions
//   Layer 2: Recent Work      (~400-600)    — top drawers by recency
//
// When `wing_filter` is null the caller should pass the project-derived
// default wing so personal and work memories don't bleed together.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const profile_mod = @import("profile.zig");
const facts_mod = @import("facts.zig");

const Allocator = std.mem.Allocator;

const MAX_L1_DRAWERS = 8;
const MAX_L2_DRAWERS = 12;
const MAX_L1_CHARS: usize = 1800;
const MAX_L2_CHARS: usize = 2200;
const DRAWER_PREVIEW_LEN: usize = 200;

/// Generate the full L0+L1+L2 wake-up context string.
pub fn generate(database: *db.Database, wing_filter: ?[]const u8, allocator: Allocator) ![]u8 {
    // ── Layer 0: Identity ──
    const identity = loadIdentity(allocator);
    defer if (identity.allocated) allocator.free(identity.text);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "## L0 — IDENTITY\n");
    try out.appendSlice(allocator, identity.text);
    try out.appendSlice(allocator, "\n\n");

    // Track drawer ids already shown so L2 doesn't repeat L1.
    var seen_ids: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer seen_ids.deinit(allocator);

    // ── Layer 1: Project Profile (versioned entries + decision drawers) ──
    try out.appendSlice(allocator, "## L1 — PROJECT PROFILE\n");
    var l1_count: usize = 0;
    if (wing_filter) |wf| {
        // Prefer structured profile_entries when the wing exists.
        if (lookupWingId(database, wf)) |wid| {
            const brief = profile_mod.renderBrief(database, wid, wf, allocator) catch null;
            if (brief) |b| {
                defer allocator.free(b);
                // Skip the header line from renderBrief; we already have L1 header.
                if (std.mem.indexOfScalar(u8, b, '\n')) |nl| {
                    try out.appendSlice(allocator, b[nl + 1 ..]);
                } else {
                    try out.appendSlice(allocator, b);
                }
                if (profile_mod.listActive(database, wid, 20, allocator)) |ents| {
                    defer profile_mod.freeEntries(ents, allocator);
                    l1_count = ents.len;
                } else |_| {}

                // Also list active facts as compact bullets if profile empty-ish.
                if (l1_count < 3) {
                    if (facts_mod.listActive(database, wid, 8, allocator)) |fl| {
                        defer facts_mod.freeFacts(fl, allocator);
                        for (fl) |f| {
                            const line = try std.fmt.allocPrint(allocator, "- [fact] {s} {s} {s}\n", .{ f.subject, f.predicate, f.object });
                            defer allocator.free(line);
                            try out.appendSlice(allocator, line);
                            l1_count += 1;
                        }
                    } else |_| {}
                }
            }
        }
    }
    const drawer_l1 = try appendProfileLayer(database, wing_filter, allocator, &out, &seen_ids);
    l1_count += drawer_l1;
    if (l1_count == 0) {
        try out.appendSlice(allocator, "(no stored decisions/profile yet — use memory_store with room \"decisions\")\n");
    }
    try out.appendSlice(allocator, "\n");

    // ── Layer 2: Recent Work ──
    try out.appendSlice(allocator, "## L2 — RECENT WORK\n");
    const l2_count = try appendRecentLayer(database, wing_filter, allocator, &out, &seen_ids);
    if (l2_count == 0) {
        if (l1_count == 0) {
            try out.appendSlice(allocator, "Palace is empty. Run: memxt mine <dir> or memxt adopt\n");
        } else {
            try out.appendSlice(allocator, "(all recent items already listed in profile)\n");
        }
    }

    const wing_note = if (wing_filter) |w|
        try std.fmt.allocPrint(allocator, "\n({d} profile + {d} recent · wing={s} · ~{d} tokens)\n", .{
            l1_count, l2_count, w, out.items.len / 4,
        })
    else
        try std.fmt.allocPrint(allocator, "\n({d} profile + {d} recent · ~{d} tokens)\n", .{
            l1_count, l2_count, out.items.len / 4,
        });
    defer allocator.free(wing_note);
    try out.appendSlice(allocator, wing_note);

    return out.toOwnedSlice(allocator);
}

/// Serve the wake brief from the dream daemon's precomputed cache when fresh
/// (younger than the daemon interval), falling back to live assembly. The
/// wake_cache table only exists once `memxt dream --daemon` has run; a missing
/// table simply means "no cache" and we assemble live.
pub fn generateCached(database: *db.Database, wing_filter: ?[]const u8, allocator: Allocator) ![]u8 {
    if (cachedBrief(database, wing_filter, allocator)) |brief| return brief;
    return generate(database, wing_filter, allocator);
}

fn cachedBrief(database: *db.Database, wing_filter: ?[]const u8, allocator: Allocator) ?[]u8 {
    // prepare fails when wake_cache doesn't exist yet → fall back to live.
    const stmt = database.prepare(
        \\SELECT brief FROM wake_cache
        \\WHERE wing = ? AND generated_at > strftime('%s','now') - ?
    ) orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, wing_filter orelse ""); // global brief cached under ''
    db.bindInt64(stmt, 2, cacheMaxAgeSecs(database));
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const brief = db.columnText(stmt, 0) orelse return null;
    if (brief.len == 0) return null;
    return allocator.dupe(u8, brief) catch null;
}

/// "Fresh" = younger than the daemon's cycle interval (stamped in config by
/// dreamd). Defaults to 60 minutes when the daemon never recorded one.
fn cacheMaxAgeSecs(database: *db.Database) i64 {
    const stmt = database.prepare("SELECT value FROM config WHERE key = 'dreamd_interval_mins'") orelse return 3600;
    defer db.finalize(stmt);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 3600;
    const v = db.columnText(stmt, 0) orelse return 3600;
    const mins = std.fmt.parseInt(i64, v, 10) catch return 3600;
    return std.math.clamp(mins, 1, 24 * 60) * 60;
}

/// Test seam: expose the cache lookup without the live-assembly fallback.
pub fn cachedBriefForTest(database: *db.Database, wing_filter: ?[]const u8, allocator: Allocator) ?[]u8 {
    return cachedBrief(database, wing_filter, allocator);
}

/// Profile-ish rooms and source types: decisions, conventions, profile, notes from agent.
fn appendProfileLayer(
    database: *db.Database,
    wing_filter: ?[]const u8,
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    seen_ids: *std.AutoHashMapUnmanaged(i64, void),
) !usize {
    // Prefer drawers that look like durable facts: agent memories, decision rooms,
    // profile/conventions rooms. Fall back to nothing if none match (don't spam L1
    // with raw mined code — that belongs in L2).
    const sql = if (wing_filter != null)
        \\SELECT d.id, d.content, d.source_path, r.name, w.name, d.created_at
        \\FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\JOIN wings w ON w.id = r.wing_id
        \\WHERE w.name = ?
        \\  AND (
        \\    d.source_type IN ('memory', 'decision', 'profile')
        \\    OR lower(r.name) IN ('decisions', 'decision', 'profile', 'conventions', 'notes', 'architecture', 'adr')
        \\  )
        \\ORDER BY d.created_at DESC
        \\LIMIT ?
    else
        \\SELECT d.id, d.content, d.source_path, r.name, w.name, d.created_at
        \\FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\JOIN wings w ON w.id = r.wing_id
        \\WHERE d.source_type IN ('memory', 'decision', 'profile')
        \\   OR lower(r.name) IN ('decisions', 'decision', 'profile', 'conventions', 'notes', 'architecture', 'adr')
        \\ORDER BY d.created_at DESC
        \\LIMIT ?
    ;

    return appendFromQuery(database, sql, wing_filter, MAX_L1_DRAWERS, MAX_L1_CHARS, allocator, out, seen_ids);
}

fn appendRecentLayer(
    database: *db.Database,
    wing_filter: ?[]const u8,
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    seen_ids: *std.AutoHashMapUnmanaged(i64, void),
) !usize {
    const sql = if (wing_filter != null)
        \\SELECT d.id, d.content, d.source_path, r.name, w.name, d.created_at
        \\FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\JOIN wings w ON w.id = r.wing_id
        \\WHERE w.name = ?
        \\ORDER BY d.created_at DESC
        \\LIMIT ?
    else
        \\SELECT d.id, d.content, d.source_path, r.name, w.name, d.created_at
        \\FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\JOIN wings w ON w.id = r.wing_id
        \\ORDER BY d.created_at DESC
        \\LIMIT ?
    ;

    // Over-fetch so we still fill L2 after skipping L1 duplicates.
    const fetch_limit: i32 = MAX_L2_DRAWERS + MAX_L1_DRAWERS;
    return appendFromQuery(database, sql, wing_filter, fetch_limit, MAX_L2_CHARS, allocator, out, seen_ids);
}

fn appendFromQuery(
    database: *db.Database,
    sql: []const u8,
    wing_filter: ?[]const u8,
    limit: i32,
    max_chars: usize,
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    seen_ids: *std.AutoHashMapUnmanaged(i64, void),
) !usize {
    const stmt = database.prepare(sql) orelse return 0;
    defer db.finalize(stmt);

    if (wing_filter) |wf| {
        db.bindText(stmt, 1, wf);
        db.bindInt(stmt, 2, limit);
    } else {
        db.bindInt(stmt, 1, limit);
    }

    var total_chars: usize = 0;
    var count: usize = 0;

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        if (total_chars >= max_chars) break;
        if (count >= MAX_L2_DRAWERS and limit > MAX_L1_DRAWERS) break;

        const drawer_id = db.columnInt64(stmt, 0);
        if (seen_ids.contains(drawer_id)) continue;

        const content = db.columnText(stmt, 1) orelse continue;
        const source = db.columnText(stmt, 2) orelse "";
        const room = db.columnText(stmt, 3) orelse "";
        const wing = db.columnText(stmt, 4) orelse "";

        const preview_len = @min(content.len, DRAWER_PREVIEW_LEN);
        const suffix: []const u8 = if (content.len > DRAWER_PREVIEW_LEN) "..." else "";

        const line = try std.fmt.allocPrint(allocator, "- [#{d} {s}/{s}] ({s}) {s}{s}\n", .{
            drawer_id, wing, room, source, content[0..preview_len], suffix,
        });
        defer allocator.free(line);

        try out.appendSlice(allocator, line);
        try seen_ids.put(allocator, drawer_id, {});

        total_chars += preview_len;
        count += 1;
    }

    return count;
}

fn lookupWingId(database: *db.Database, name: []const u8) ?i64 {
    const stmt = database.prepare("SELECT id FROM wings WHERE name = ?") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, name);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return null;
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

    const text = allocator.realloc(buf, bytes_read) catch buf[0..bytes_read];
    return .{ .text = text, .allocated = true };
}
