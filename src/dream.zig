// ═══════════════════════════════════════════════════════════════════
// memxt/dream.zig — Consolidation: expire, demote, cluster, budget
//
// Keeps query path fast by bounding the hot vector set while retaining
// all verbatim content (FTS still searches cold drawers).
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const palace_mod = @import("palace.zig");
const facts_mod = @import("facts.zig");
const embedder = @import("embedder.zig");
const telemetry = @import("telemetry.zig");

const Allocator = std.mem.Allocator;

pub const DreamOptions = struct {
    /// Max drawers that keep a hot vector. Default 50_000.
    hot_budget: i64 = 50_000,
    /// Demote episode/session drawers older than this many days if low access.
    episode_ttl_days: i64 = 30,
    /// Never demote these kinds.
    pin_decisions: bool = true,
    wing: ?[]const u8 = null,
    dry_run: bool = false,
    /// Build extractive clusters for recent episodes.
    build_clusters: bool = true,
};

pub const DreamReport = struct {
    facts_expired: u32 = 0,
    demoted: u32 = 0,
    clusters_built: u32 = 0,
    hot_before: i64 = 0,
    hot_after: i64 = 0,
    quant_count: i64 = 0,
    drawers_total: i64 = 0,
};

pub fn run(database: *db.Database, opts: DreamOptions, allocator: Allocator) !DreamReport {
    database.createPalaceSchema();
    var pal = palace_mod.Palace.init(database, allocator);
    var report = DreamReport{};
    report.hot_before = pal.hotVectorCount();
    report.drawers_total = pal.drawerCount();

    // 1) Expire stale facts
    report.facts_expired = facts_mod.expireStale(database);

    // 2) Demote old low-access episodes
    report.demoted += try demoteOldEpisodes(database, &pal, opts);

    // 2b) Usage noise: drawers surfaced many times but never fetched over a
    // long window are preferred demotion candidates (see telemetry.zig).
    report.demoted += try demoteSurfacedNeverFetched(database, &pal, opts, allocator);

    // 3) Hierarchical clusters (extractive summaries) — before budget so we can demote them if over
    if (opts.build_clusters and !opts.dry_run) {
        report.clusters_built = try buildClusters(database, &pal, opts, allocator);
    }

    // 4) Enforce hot vector budget (never demotes decision/procedure/summary)
    report.demoted += try enforceHotBudget(database, &pal, opts);

    // Stamp last dream time
    if (!opts.dry_run) {
        database.exec("INSERT OR REPLACE INTO config(key, value) VALUES('last_dream_at', strftime('%s','now'))");
    }

    report.hot_after = pal.hotVectorCount();
    report.quant_count = pal.quantCount();
    return report;
}

pub fn formatReport(report: DreamReport, allocator: Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\╔══════════════════════════════════════════╗
        \\║         🌙  memxt dream — report          ║
        \\╠══════════════════════════════════════════╣
        \\║  Drawers total:     {d:>8}                ║
        \\║  Hot vectors before:{d:>8}                ║
        \\║  Hot vectors after: {d:>8}                ║
        \\║  Quantized (cold):  {d:>8}  (TurboQuant)  ║
        \\║  Demoted to cold:   {d:>8}                ║
        \\║  Facts expired:     {d:>8}                ║
        \\║  Clusters built:    {d:>8}                ║
        \\╚══════════════════════════════════════════╝
        \\
        \\Cold drawers keep 4-bit quantized vectors (~6× smaller) + FTS.
        \\Pinned: decision / procedure / summary stay f32 hot.
        \\
    , .{
        @as(u64, @intCast(@max(0, report.drawers_total))),
        @as(u64, @intCast(@max(0, report.hot_before))),
        @as(u64, @intCast(@max(0, report.hot_after))),
        @as(u64, @intCast(@max(0, report.quant_count))),
        report.demoted,
        report.facts_expired,
        report.clusters_built,
    });
}

fn demoteOldEpisodes(database: *db.Database, pal: *palace_mod.Palace, opts: DreamOptions) !u32 {
    const ttl_secs = opts.episode_ttl_days * 86400;
    // Select cold candidates: episode/session, old, low access, still hot.
    const sql =
        \\SELECT d.id FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\JOIN wings w ON w.id = r.wing_id
        \\JOIN vec_drawers v ON v.id = d.id
        \\WHERE COALESCE(d.kind, '') IN ('episode')
        \\  AND COALESCE(d.tier, 'hot') IN ('hot', 'warm')
        \\  AND d.created_at < strftime('%s','now') - ?
        \\  AND COALESCE(d.access_count, 0) < 3
        \\ORDER BY d.created_at ASC
        \\LIMIT 5000
    ;
    const stmt = database.prepare(sql) orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, ttl_secs);

    var n: u32 = 0;
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const id = db.columnInt64(stmt, 0);
        if (opts.wing) |w| {
            // Filter by wing if set — re-check
            if (!drawerInWing(database, id, w)) continue;
        }
        // Usage-learned: frequently fetched drawers resist demotion.
        if (telemetry.resistsDemotion(database, id)) continue;
        if (!opts.dry_run) {
            try pal.demoteToCold(id);
        }
        n += 1;
    }
    return n;
}

/// Demote drawers the agent keeps seeing in search indexes but never opens.
/// Candidates come from local retrieval telemetry; pinned kinds and
/// already-cold drawers are skipped.
fn demoteSurfacedNeverFetched(
    database: *db.Database,
    pal: *palace_mod.Palace,
    opts: DreamOptions,
    allocator: Allocator,
) !u32 {
    const ids = telemetry.noiseCandidates(database, 1000, allocator) catch return 0;
    defer allocator.free(ids);

    var n: u32 = 0;
    for (ids) |id| {
        if (!drawerHotUnpinned(database, id)) continue;
        if (opts.wing) |w| {
            if (!drawerInWing(database, id, w)) continue;
        }
        if (!opts.dry_run) {
            try pal.demoteToCold(id);
        }
        n += 1;
    }
    return n;
}

/// Still holds a hot f32 vector and is not a pinned kind.
fn drawerHotUnpinned(database: *db.Database, drawer_id: i64) bool {
    const stmt = database.prepare(
        \\SELECT 1 FROM drawers d
        \\JOIN vec_drawers v ON v.id = d.id
        \\WHERE d.id = ?
        \\  AND COALESCE(d.kind, 'document') NOT IN ('decision', 'procedure', 'summary')
    ) orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, drawer_id);
    return db.step(stmt) == db.c.SQLITE_ROW;
}

fn enforceHotBudget(database: *db.Database, pal: *palace_mod.Palace, opts: DreamOptions) !u32 {
    const hot = pal.hotVectorCount();
    if (hot <= opts.hot_budget) return 0;
    const excess = hot - opts.hot_budget;

    // Demote least-accessed, oldest non-pinned drawers still in vec.
    const sql =
        \\SELECT d.id FROM drawers d
        \\JOIN vec_drawers v ON v.id = d.id
        \\WHERE COALESCE(d.kind, 'document') NOT IN ('decision', 'procedure', 'summary')
        \\ORDER BY COALESCE(d.access_count, 0) ASC, d.created_at ASC
        \\LIMIT ?
    ;
    const stmt = database.prepare(sql) orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, excess + 100); // a little headroom

    var n: u32 = 0;
    while (db.step(stmt) == db.c.SQLITE_ROW and n < @as(u32, @intCast(excess))) {
        const id = db.columnInt64(stmt, 0);
        if (opts.wing) |w| {
            if (!drawerInWing(database, id, w)) continue;
        }
        // Usage-learned: frequently fetched drawers resist demotion.
        if (telemetry.resistsDemotion(database, id)) continue;
        if (!opts.dry_run) {
            try pal.demoteToCold(id);
        }
        n += 1;
    }
    return n;
}

fn drawerInWing(database: *db.Database, drawer_id: i64, wing: []const u8) bool {
    const stmt = database.prepare(
        \\SELECT 1 FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\JOIN wings w ON w.id = r.wing_id
        \\WHERE d.id = ? AND w.name = ?
    ) orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, drawer_id);
    db.bindText(stmt, 2, wing);
    return db.step(stmt) == db.c.SQLITE_ROW;
}

/// Build one extractive cluster per wing from recent episode/memory drawers.
fn buildClusters(
    database: *db.Database,
    pal: *palace_mod.Palace,
    opts: DreamOptions,
    allocator: Allocator,
) !u32 {
    _ = opts;
    // List wings
    const wings = try pal.listWings(allocator);
    defer {
        for (wings) |w| {
            allocator.free(w.name);
            allocator.free(w.description);
            allocator.free(w.wing_type);
        }
        allocator.free(wings);
    }

    var built: u32 = 0;
    for (wings) |w| {
        const members = try recentMemberIds(database, w.id, 8, allocator);
        defer allocator.free(members);
        if (members.len < 2) continue;

        var summary: std.ArrayListUnmanaged(u8) = .empty;
        defer summary.deinit(allocator);
        try summary.appendSlice(allocator, "Cluster: recent activity\n");

        var id_list: std.ArrayListUnmanaged(u8) = .empty;
        defer id_list.deinit(allocator);

        for (members, 0..) |mid, i| {
            if (i > 0) try id_list.append(allocator, ',');
            const id_s = try std.fmt.allocPrint(allocator, "{d}", .{mid});
            defer allocator.free(id_s);
            try id_list.appendSlice(allocator, id_s);

            const preview = drawerPreview(database, mid, allocator) catch continue;
            defer allocator.free(preview);
            try summary.appendSlice(allocator, "- ");
            try summary.appendSlice(allocator, preview);
            try summary.append(allocator, '\n');
        }

        // Store as a summary drawer (pinned hot) + clusters row
        const room_id = try pal.createRoom(w.id, "clusters", "dream clusters");
        var emb: []const f32 = &[_]f32{};
        var emb_owned = false;
        if (embedder.isReady() or true) {
            // Lazy path: try embed if model path was set
            if (embedder.embed(summary.items, allocator)) |e| {
                emb = e;
                emb_owned = true;
            } else |_| {}
        }
        defer if (emb_owned) allocator.free(emb);

        const drawer_id = try pal.insertDrawerKind(
            room_id,
            summary.items,
            "dream",
            "summary",
            0,
            emb,
            "summary",
            null,
        );

        const ins = database.prepare(
            "INSERT INTO clusters(wing_id, summary, member_ids, drawer_id) VALUES(?, ?, ?, ?)",
        ) orelse continue;
        defer db.finalize(ins);
        db.bindInt64(ins, 1, w.id);
        db.bindText(ins, 2, summary.items);
        db.bindText(ins, 3, id_list.items);
        db.bindInt64(ins, 4, drawer_id);
        if (db.step(ins) == db.c.SQLITE_DONE) built += 1;
    }
    return built;
}

fn recentMemberIds(database: *db.Database, wing_id: i64, limit: i32, allocator: Allocator) ![]i64 {
    const stmt = database.prepare(
        \\SELECT d.id FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\WHERE r.wing_id = ?
        \\  AND COALESCE(d.kind, '') IN ('episode', 'memory', 'decision')
        \\ORDER BY d.created_at DESC
        \\LIMIT ?
    ) orelse return try allocator.alloc(i64, 0);
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, wing_id);
    db.bindInt(stmt, 2, limit);

    var list: std.ArrayListUnmanaged(i64) = .empty;
    errdefer list.deinit(allocator);
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        try list.append(allocator, db.columnInt64(stmt, 0));
    }
    return list.toOwnedSlice(allocator);
}

fn drawerPreview(database: *db.Database, id: i64, allocator: Allocator) ![]u8 {
    const stmt = database.prepare("SELECT content FROM drawers WHERE id = ?") orelse return error.PrepareFailed;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return error.NotFound;
    const content = db.columnText(stmt, 0) orelse "";
    const n = @min(content.len, 120);
    return try allocator.dupe(u8, content[0..n]);
}
