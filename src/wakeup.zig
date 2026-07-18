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
const packer = @import("packer.zig");

const Allocator = std.mem.Allocator;

const MAX_L1_DRAWERS = 8;
const MAX_L2_DRAWERS = 12;
const MAX_L1_CHARS: usize = 1800;
const MAX_L2_CHARS: usize = 2200;
const DRAWER_PREVIEW_LEN: usize = 200;

/// Content-level dedup for brief assembly. The same decision can exist three
/// ways at once — as a profile entry, an extracted fact, and the decision
/// drawer itself — with slightly different wording ("Decision is we chose…"
/// vs "Decision: we chose…"), so id- and exact-match dedup both miss it.
/// Instead each emitted line registers its set of word hashes; a candidate is
/// a duplicate when ≥85% of the smaller set already appears in some earlier
/// line's set. Lines under 3 words never dedup (too little signal).
const ContentDedup = struct {
    entries: std.ArrayListUnmanaged([]u64) = .empty,

    fn deinit(self: *ContentDedup, allocator: Allocator) void {
        for (self.entries.items) |e| allocator.free(e);
        self.entries.deinit(allocator);
    }

    /// True (and does not register) when `text` substantially repeats an
    /// earlier line; false (and registers it) when it is new.
    fn isDupOrAdd(self: *ContentDedup, text: []const u8, allocator: Allocator) bool {
        const words = wordHashes(text, allocator) catch return false;
        if (words.len == 0) {
            allocator.free(words);
            return false;
        }
        for (self.entries.items) |prev| {
            const smaller = @min(words.len, prev.len);
            if (smaller < 3) continue;
            if (intersectCount(words, prev) * 100 >= smaller * 85) {
                allocator.free(words);
                return true;
            }
        }
        self.entries.append(allocator, words) catch {
            allocator.free(words);
            return false;
        };
        return false;
    }
};

/// Sorted, unique hashes of the lowercase alphanumeric words (len ≥ 2) in
/// `text`, capped at 48 words.
fn wordHashes(text: []const u8, allocator: Allocator) ![]u64 {
    var list: std.ArrayListUnmanaged(u64) = .empty;
    errdefer list.deinit(allocator);

    var word_buf: [64]u8 = undefined;
    var wlen: usize = 0;
    var i: usize = 0;
    while (i <= text.len and list.items.len < 48) : (i += 1) {
        const ch: u8 = if (i < text.len) text[i] else ' ';
        if (std.ascii.isAlphanumeric(ch)) {
            if (wlen < word_buf.len) {
                word_buf[wlen] = std.ascii.toLower(ch);
                wlen += 1;
            }
        } else if (wlen > 0) {
            if (wlen >= 2) try list.append(allocator, std.hash.Wyhash.hash(0, word_buf[0..wlen]));
            wlen = 0;
        }
    }

    const slice = try list.toOwnedSlice(allocator);
    std.mem.sort(u64, slice, {}, std.sort.asc(u64));
    var n: usize = 0;
    for (slice) |h| {
        if (n == 0 or slice[n - 1] != h) {
            slice[n] = h;
            n += 1;
        }
    }
    if (n == slice.len) return slice;
    defer allocator.free(slice);
    return allocator.dupe(u64, slice[0..n]);
}

fn intersectCount(a: []const u64, b: []const u64) usize {
    var i: usize = 0;
    var j: usize = 0;
    var n: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] == b[j]) {
            n += 1;
            i += 1;
            j += 1;
        } else if (a[i] < b[j]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    return n;
}

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

    // Track drawer ids already shown so L2 doesn't repeat L1, and line
    // content so the same decision isn't listed as profile entry AND fact
    // AND drawer.
    var seen_ids: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer seen_ids.deinit(allocator);
    var dedup = ContentDedup{};
    defer dedup.deinit(allocator);

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
                const body = if (std.mem.indexOfScalar(u8, b, '\n')) |nl| b[nl + 1 ..] else b;
                try out.appendSlice(allocator, body);
                // Profile entries print first, so they win dedup: register
                // each line so facts/drawers repeating them get skipped.
                var line_it = std.mem.splitScalar(u8, body, '\n');
                while (line_it.next()) |line| {
                    if (line.len > 0) _ = dedup.isDupOrAdd(line, allocator);
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
                            const core = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ f.subject, f.predicate, f.object });
                            defer allocator.free(core);
                            if (dedup.isDupOrAdd(core, allocator)) continue;
                            const line = try std.fmt.allocPrint(allocator, "- [fact] {s}\n", .{core});
                            defer allocator.free(line);
                            try out.appendSlice(allocator, line);
                            l1_count += 1;
                        }
                    } else |_| {}
                }
            }
        }
    }
    const drawer_l1 = try appendProfileLayer(database, wing_filter, allocator, &out, &seen_ids, &dedup);
    l1_count += drawer_l1;
    if (l1_count == 0) {
        try out.appendSlice(allocator, "(no stored decisions/profile yet — use memory_store with room \"decisions\")\n");
    }
    try out.appendSlice(allocator, "\n");

    // ── Layer 2: Recent Work ──
    try out.appendSlice(allocator, "## L2 — RECENT WORK\n");
    const l2_count = try appendRecentLayer(database, wing_filter, allocator, &out, &seen_ids, &dedup);
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

/// Budget-aware variant: take the wake brief (daemon cache when fresh, live
/// assembly otherwise), then fit it to `budget_tokens` through the packer.
/// The packer trims from the end at line/sentence boundaries, so layers keep
/// priority order L0 > L1 > L2. A null budget keeps default behavior
/// (identical to `generateCached`).
pub fn generateBudgeted(
    database: *db.Database,
    wing_filter: ?[]const u8,
    budget_tokens: ?usize,
    allocator: Allocator,
) ![]u8 {
    const full = try generateCached(database, wing_filter, allocator);
    const budget = budget_tokens orelse return full;
    if (packer.estimateTokens(full) <= budget) return full;
    defer allocator.free(full);
    return packer.fitToBudget(full, budget, allocator);
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
    dedup: *ContentDedup,
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

    return appendFromQuery(database, sql, wing_filter, MAX_L1_DRAWERS, MAX_L1_CHARS, allocator, out, seen_ids, dedup);
}

fn appendRecentLayer(
    database: *db.Database,
    wing_filter: ?[]const u8,
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    seen_ids: *std.AutoHashMapUnmanaged(i64, void),
    dedup: *ContentDedup,
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
    return appendFromQuery(database, sql, wing_filter, fetch_limit, MAX_L2_CHARS, allocator, out, seen_ids, dedup);
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
    dedup: *ContentDedup,
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

        // Content already covered by a profile entry or fact bullet: skip the
        // drawer, and mark it seen so L2 doesn't resurrect it either.
        if (dedup.isDupOrAdd(content[0..preview_len], allocator)) {
            try seen_ids.put(allocator, drawer_id, {});
            continue;
        }

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

// ── tests ──

test "content dedup: near-identical wording across sources is caught" {
    const allocator = std.testing.allocator;
    var dedup = ContentDedup{};
    defer dedup.deinit(allocator);

    // Profile entry registers first…
    try std.testing.expect(!dedup.isDupOrAdd(
        "- **Decision.is**: we chose SQLite over Postgres for local state — zero ops, a single file, and WAL gives us all the concurrency we need.",
        allocator,
    ));
    // …the extracted fact ("Decision is we chose…") is a duplicate…
    try std.testing.expect(dedup.isDupOrAdd(
        "Decision is we chose SQLite over Postgres for local state — zero ops, a single file, and WAL gives us all the concurrency we need.",
        allocator,
    ));
    // …and so is the raw decision drawer ("Decision: we chose…").
    try std.testing.expect(dedup.isDupOrAdd(
        "Decision: we chose SQLite over Postgres for local state — zero ops, a single file, and WAL gives us all the concurrency we need.",
        allocator,
    ));
}

test "content dedup: short fact contained in a longer decision is caught" {
    const allocator = std.testing.allocator;
    var dedup = ContentDedup{};
    defer dedup.deinit(allocator);

    try std.testing.expect(!dedup.isDupOrAdd(
        "Decision: the cart cap is 37 items per order. Anything larger trips the fraud checks downstream.",
        allocator,
    ));
    try std.testing.expect(dedup.isDupOrAdd("cart cap is 37", allocator));
}

test "content dedup: distinct decisions are not merged" {
    const allocator = std.testing.allocator;
    var dedup = ContentDedup{};
    defer dedup.deinit(allocator);

    try std.testing.expect(!dedup.isDupOrAdd(
        "Decision: Redis is banned in this codebase — cache invalidation bugs ate two weekends.",
        allocator,
    ));
    try std.testing.expect(!dedup.isDupOrAdd(
        "Decision: we chose SQLite over Postgres for local state.",
        allocator,
    ));
    try std.testing.expect(!dedup.isDupOrAdd(
        "Decision: the cart cap is 37 items per order.",
        allocator,
    ));
}

test "content dedup: lines under three words never dedup" {
    const allocator = std.testing.allocator;
    var dedup = ContentDedup{};
    defer dedup.deinit(allocator);

    try std.testing.expect(!dedup.isDupOrAdd("use SQLite", allocator));
    try std.testing.expect(!dedup.isDupOrAdd("use SQLite", allocator));
}
