// ═══════════════════════════════════════════════════════════════════
// memxt/telemetry.zig — usage-learned relevance (local retrieval telemetry)
//
// The signal already exists in the flow: memory_search returns an index,
// then the agent calls memory_get on the ids it actually wants. A drawer
// that keeps getting fetched is useful; one that surfaces but never gets
// opened is noise. We log both events locally, keep cheap aggregates, and
// feed a Laplace-smoothed fetch-through rate (plus recency decay) back
// into search ranking and dream-time demotion. Nothing leaves the machine.
//
// All writes are best-effort: telemetry must never fail a request.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("time.h");
});

// ── Tunables (the whole blend lives here) ──

/// Recency half-life for the utility score, in days. Override with
/// MEMXT_UTILITY_HALFLIFE_DAYS.
pub const DEFAULT_HALFLIFE_DAYS: f64 = 30.0;
pub const HALFLIFE_ENV = "MEMXT_UTILITY_HALFLIFE_DAYS";

/// utility = RATE_WEIGHT * fetch-through-rate + RECENCY_WEIGHT * decay.
pub const RATE_WEIGHT: f64 = 0.7;
pub const RECENCY_WEIGHT: f64 = 0.3;

/// Ranking blend strength. memxt scores are LOWER = better (and can go
/// negative), so the classic higher-is-better multiplicative boost
/// `base * (0.8 + 0.4 * utility)` maps to a bounded, centered subtraction:
/// boosted = score - UTILITY_WEIGHT * (utility - UTILITY_NEUTRAL).
/// Max shift is ±UTILITY_WEIGHT/2 (±0.1) — enough to tilt near-ties,
/// never enough to drown semantic relevance.
pub const UTILITY_WEIGHT: f64 = 0.2;
pub const UTILITY_NEUTRAL: f64 = 0.5;

/// Dream: a drawer resists demotion when it was actually opened at least
/// this many times AND its utility is still at least RESIST_UTILITY_MIN.
pub const RESIST_MIN_FETCHED: i64 = 2;
pub const RESIST_UTILITY_MIN: f64 = 0.6;

/// Dream: a drawer becomes a preferred demotion candidate when it surfaced
/// at least NOISE_MIN_SURFACED times over a window of at least
/// NOISE_WINDOW_DAYS without ever being fetched.
pub const NOISE_MIN_SURFACED: i64 = 5;
pub const NOISE_WINDOW_DAYS: i64 = 14;

// ── Tables ──

/// Create telemetry tables if missing. Deliberately NOT part of the
/// versioned palace schema (no SCHEMA_VERSION bump): purely additive,
/// safe to call repeatedly, and every reader tolerates their absence.
pub fn ensureTables(database: *db.Database) void {
    database.exec(
        \\CREATE TABLE IF NOT EXISTS retrieval_log (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  drawer_id INTEGER NOT NULL,
        \\  event TEXT NOT NULL CHECK (event IN ('surfaced','fetched')),
        \\  ts INTEGER DEFAULT (strftime('%s','now'))
        \\)
    );
    database.exec("CREATE INDEX IF NOT EXISTS idx_retrieval_drawer ON retrieval_log(drawer_id)");
    // Aggregates maintained on every log write so scoring never scans the log.
    database.exec(
        \\CREATE TABLE IF NOT EXISTS drawer_utility (
        \\  drawer_id INTEGER PRIMARY KEY,
        \\  surfaced_n INTEGER NOT NULL DEFAULT 0,
        \\  fetched_n INTEGER NOT NULL DEFAULT 0,
        \\  last_fetched INTEGER
        \\)
    );
}

// ── Event recording (best-effort, never fails the request) ──

/// A drawer id was returned in a memory_search index.
pub fn recordSurfaced(database: *db.Database, drawer_id: i64) void {
    record(database, drawer_id, "surfaced");
}

/// A drawer body was actually fetched via memory_get.
pub fn recordFetched(database: *db.Database, drawer_id: i64) void {
    record(database, drawer_id, "fetched");
}

fn record(database: *db.Database, drawer_id: i64, event: []const u8) void {
    // Synthetic fact hits use negative ids; they are not drawers.
    if (drawer_id <= 0) return;
    ensureTables(database);

    const log = database.prepare(
        "INSERT INTO retrieval_log(drawer_id, event) VALUES(?, ?)",
    ) orelse return;
    defer db.finalize(log);
    db.bindInt64(log, 1, drawer_id);
    db.bindText(log, 2, event);
    _ = db.step(log);

    const upsert_sql = if (std.mem.eql(u8, event, "fetched"))
        \\INSERT INTO drawer_utility(drawer_id, surfaced_n, fetched_n, last_fetched)
        \\VALUES(?, 0, 1, strftime('%s','now'))
        \\ON CONFLICT(drawer_id) DO UPDATE SET
        \\  fetched_n = fetched_n + 1,
        \\  last_fetched = strftime('%s','now')
    else
        \\INSERT INTO drawer_utility(drawer_id, surfaced_n, fetched_n)
        \\VALUES(?, 1, 0)
        \\ON CONFLICT(drawer_id) DO UPDATE SET surfaced_n = surfaced_n + 1
    ;
    const up = database.prepare(upsert_sql) orelse return;
    defer db.finalize(up);
    db.bindInt64(up, 1, drawer_id);
    _ = db.step(up);
}

// ── Score math (pure — unit-testable without a database) ──

/// Laplace-smoothed fetch-through rate: (fetched + 1) / (surfaced + 2).
/// No data → 0.5 (neutral); heavily surfaced but never fetched → ~0.
pub fn fetchThroughRate(surfaced_n: i64, fetched_n: i64) f64 {
    const s: f64 = @floatFromInt(@max(0, surfaced_n));
    const f: f64 = @floatFromInt(@max(0, fetched_n));
    return (f + 1.0) / (s + 2.0);
}

/// Exponential decay from the last fetch: 1.0 right now, 0.5 after one
/// half-life, → 0 as the fetch ages out. Never fetched → 0.
pub fn recencyDecay(last_fetched: ?i64, now_ts: i64, half_life_days: f64) f64 {
    const lf = last_fetched orelse return 0.0;
    if (lf >= now_ts) return 1.0;
    if (!(half_life_days > 0)) return 0.0;
    const age_days = @as(f64, @floatFromInt(now_ts - lf)) / 86400.0;
    return @exp2(-age_days / half_life_days);
}

/// Combined utility in [0, 1]: mostly the fetch-through rate, sweetened
/// when the drawer was fetched recently.
pub fn utilityScore(
    surfaced_n: i64,
    fetched_n: i64,
    last_fetched: ?i64,
    now_ts: i64,
    half_life_days: f64,
) f64 {
    const rate = fetchThroughRate(surfaced_n, fetched_n);
    const rec = recencyDecay(last_fetched, now_ts, half_life_days);
    return std.math.clamp(RATE_WEIGHT * rate + RECENCY_WEIGHT * rec, 0.0, 1.0);
}

/// THE ranking blend — the single place the boost formula lives.
/// Score convention is LOWER = better (see searcher.zig), so high utility
/// subtracts and low utility adds, centered on UTILITY_NEUTRAL so drawers
/// with average usage are untouched. Bounded to ±UTILITY_WEIGHT/2.
pub fn applyUtilityBoost(score: f64, utility: f64) f64 {
    const u = std.math.clamp(utility, 0.0, 1.0);
    return score - UTILITY_WEIGHT * (u - UTILITY_NEUTRAL);
}

/// Effective half-life in days (env override, falling back to the default).
pub fn halfLifeDays() f64 {
    const raw = c.getenv(HALFLIFE_ENV) orelse return DEFAULT_HALFLIFE_DAYS;
    const v = std.fmt.parseFloat(f64, std.mem.span(raw)) catch return DEFAULT_HALFLIFE_DAYS;
    if (!std.math.isFinite(v) or v <= 0) return DEFAULT_HALFLIFE_DAYS;
    return v;
}

fn nowTs() i64 {
    return @intCast(c.time(null));
}

// ── Ranking integration (used by searcher.zig) ──

/// Per-search utility lookup against the drawer_utility aggregates.
/// Bypasses cleanly (boost is the identity) when the tables are missing,
/// empty, or the drawer has no usage history.
pub const UtilityLookup = struct {
    stmt: ?*db.Stmt = null,
    now_ts: i64 = 0,
    half_life_days: f64 = DEFAULT_HALFLIFE_DAYS,

    pub fn init(database: *db.Database) UtilityLookup {
        // No telemetry ever recorded → keep ranking byte-identical.
        const probe = database.prepare("SELECT 1 FROM drawer_utility LIMIT 1") orelse return .{};
        defer db.finalize(probe);
        if (db.step(probe) != db.c.SQLITE_ROW) return .{};
        const stmt = database.prepare(
            "SELECT surfaced_n, fetched_n, COALESCE(last_fetched, 0) FROM drawer_utility WHERE drawer_id = ?",
        ) orelse return .{};
        return .{ .stmt = stmt, .now_ts = nowTs(), .half_life_days = halfLifeDays() };
    }

    pub fn deinit(self: *UtilityLookup) void {
        if (self.stmt) |s| db.finalize(s);
        self.stmt = null;
    }

    /// Blend usage utility into a fused score (lower = better). Returns the
    /// score unchanged when telemetry is empty or the drawer is unknown.
    pub fn boost(self: *UtilityLookup, drawer_id: i64, score: f64) f64 {
        const stmt = self.stmt orelse return score;
        if (drawer_id <= 0) return score;
        db.reset(stmt);
        db.bindInt64(stmt, 1, drawer_id);
        if (db.step(stmt) != db.c.SQLITE_ROW) return score;
        const surfaced = db.columnInt64(stmt, 0);
        const fetched = db.columnInt64(stmt, 1);
        const lf_raw = db.columnInt64(stmt, 2);
        const lf: ?i64 = if (lf_raw > 0) lf_raw else null;
        const u = utilityScore(surfaced, fetched, lf, self.now_ts, self.half_life_days);
        return applyUtilityBoost(score, u);
    }
};

// ── Dream integration (used by dream.zig) ──

/// True when usage says this drawer is too useful to demote to cold:
/// actually opened at least RESIST_MIN_FETCHED times and utility still
/// above RESIST_UTILITY_MIN. Missing tables / no history → false.
pub fn resistsDemotion(database: *db.Database, drawer_id: i64) bool {
    const stmt = database.prepare(
        "SELECT surfaced_n, fetched_n, COALESCE(last_fetched, 0) FROM drawer_utility WHERE drawer_id = ?",
    ) orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, drawer_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return false;
    const surfaced = db.columnInt64(stmt, 0);
    const fetched = db.columnInt64(stmt, 1);
    if (fetched < RESIST_MIN_FETCHED) return false;
    const lf_raw = db.columnInt64(stmt, 2);
    const lf: ?i64 = if (lf_raw > 0) lf_raw else null;
    const u = utilityScore(surfaced, fetched, lf, nowTs(), halfLifeDays());
    return u >= RESIST_UTILITY_MIN;
}

/// Preferred demotion candidates: surfaced at least NOISE_MIN_SURFACED
/// times, never fetched, and first surfaced at least NOISE_WINDOW_DAYS ago
/// (so fresh drawers get a fair chance to be opened). Missing tables →
/// empty slice.
pub fn noiseCandidates(database: *db.Database, limit: i64, allocator: Allocator) ![]i64 {
    const stmt = database.prepare(
        \\SELECT u.drawer_id FROM drawer_utility u
        \\WHERE u.fetched_n = 0
        \\  AND u.surfaced_n >= ?
        \\  AND COALESCE(
        \\        (SELECT MIN(l.ts) FROM retrieval_log l WHERE l.drawer_id = u.drawer_id),
        \\        strftime('%s','now'))
        \\      <= strftime('%s','now') - ?
        \\ORDER BY u.surfaced_n DESC
        \\LIMIT ?
    ) orelse return try allocator.alloc(i64, 0);
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, NOISE_MIN_SURFACED);
    db.bindInt64(stmt, 2, NOISE_WINDOW_DAYS * 86400);
    db.bindInt64(stmt, 3, limit);

    var list: std.ArrayListUnmanaged(i64) = .empty;
    errdefer list.deinit(allocator);
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        try list.append(allocator, db.columnInt64(stmt, 0));
    }
    return list.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════
// Automated Testing Suite
// ═══════════════════════════════════════════════════════════════════

const testing = std.testing;

test "fetch-through rate: Laplace smoothing" {
    // No data → neutral 0.5, never 0/0.
    try testing.expectApproxEqAbs(@as(f64, 0.5), fetchThroughRate(0, 0), 1e-12);
    // Surfaced a lot, never fetched → approaches 0 but stays positive.
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 12.0), fetchThroughRate(10, 0), 1e-12);
    // Always fetched → approaches 1 but never reaches it.
    try testing.expectApproxEqAbs(@as(f64, 11.0 / 12.0), fetchThroughRate(10, 10), 1e-12);
    // Monotone in fetches.
    try testing.expect(fetchThroughRate(10, 5) > fetchThroughRate(10, 2));
    // Negative junk is clamped, not UB.
    try testing.expectApproxEqAbs(@as(f64, 0.5), fetchThroughRate(-3, -3), 1e-12);
}

test "recency decay: half-life semantics" {
    const now_ts: i64 = 1_800_000_000;
    const hl: f64 = 30.0;
    // Never fetched → no recency signal.
    try testing.expectApproxEqAbs(@as(f64, 0.0), recencyDecay(null, now_ts, hl), 1e-12);
    // Fetched right now → full signal; future timestamps clamp to 1.
    try testing.expectApproxEqAbs(@as(f64, 1.0), recencyDecay(now_ts, now_ts, hl), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), recencyDecay(now_ts + 999, now_ts, hl), 1e-12);
    // One half-life → 0.5; two → 0.25.
    try testing.expectApproxEqAbs(@as(f64, 0.5), recencyDecay(now_ts - 30 * 86400, now_ts, hl), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.25), recencyDecay(now_ts - 60 * 86400, now_ts, hl), 1e-9);
    // Degenerate half-life → treated as fully decayed, not NaN/inf.
    try testing.expectApproxEqAbs(@as(f64, 0.0), recencyDecay(now_ts - 86400, now_ts, 0.0), 1e-12);
}

test "utility score stays in [0, 1]" {
    const now_ts: i64 = 1_800_000_000;
    const cases = [_]struct { s: i64, f: i64, lf: ?i64 }{
        .{ .s = 0, .f = 0, .lf = null },
        .{ .s = 1000, .f = 0, .lf = null },
        .{ .s = 0, .f = 1000, .lf = now_ts },
        .{ .s = 50, .f = 50, .lf = now_ts - 365 * 86400 },
        .{ .s = 3, .f = 1, .lf = now_ts + 60 },
    };
    for (cases) |case| {
        const u = utilityScore(case.s, case.f, case.lf, now_ts, 30.0);
        try testing.expect(u >= 0.0 and u <= 1.0);
    }
}

test "boost blending: bounded, centered, monotone" {
    // Neutral utility leaves the score byte-identical.
    try testing.expectApproxEqAbs(@as(f64, 0.7), applyUtilityBoost(0.7, UTILITY_NEUTRAL), 1e-12);
    // Bounded: never shifts more than UTILITY_WEIGHT/2, even for junk utility.
    const utils = [_]f64{ -3.0, 0.0, 0.25, 0.5, 0.75, 1.0, 42.0 };
    for (utils) |u| {
        const shift = applyUtilityBoost(0.9, u) - 0.9;
        try testing.expect(@abs(shift) <= UTILITY_WEIGHT / 2.0 + 1e-12);
    }
    // Monotone: higher utility → lower (better) score; works below zero too.
    try testing.expect(applyUtilityBoost(0.9, 1.0) < applyUtilityBoost(0.9, 0.0));
    try testing.expect(applyUtilityBoost(-0.2, 1.0) < -0.2);
    try testing.expect(applyUtilityBoost(-0.2, 0.0) > -0.2);
}

test "empty telemetry bypasses ranking untouched" {
    var database = try db.Database.open(":memory:");
    defer database.close();

    // Tables don't exist at all → identity boost.
    var lk = UtilityLookup.init(&database);
    defer lk.deinit();
    try testing.expectEqual(@as(f64, 0.42), lk.boost(1, 0.42));

    // Tables exist but are empty → still identity.
    ensureTables(&database);
    var lk2 = UtilityLookup.init(&database);
    defer lk2.deinit();
    try testing.expectEqual(@as(f64, 0.42), lk2.boost(1, 0.42));

    // Dream hooks are equally quiet on empty telemetry.
    try testing.expect(!resistsDemotion(&database, 1));
    const ids = try noiseCandidates(&database, 10, testing.allocator);
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 0), ids.len);
}

test "recording maintains aggregates and bends ranking" {
    var database = try db.Database.open(":memory:");
    defer database.close();

    // Drawer 1: surfaced 3×, fetched once (just now).
    recordSurfaced(&database, 1);
    recordSurfaced(&database, 1);
    recordSurfaced(&database, 1);
    recordFetched(&database, 1);
    // Drawer 3: surfaced 10×, never opened.
    for (0..10) |_| recordSurfaced(&database, 3);
    // Synthetic fact ids must never be logged.
    recordSurfaced(&database, -1);

    const stmt = database.prepare(
        "SELECT surfaced_n, fetched_n, COALESCE(last_fetched, 0) FROM drawer_utility WHERE drawer_id = 1",
    ).?;
    defer db.finalize(stmt);
    try testing.expectEqual(db.c.SQLITE_ROW, db.step(stmt));
    try testing.expectEqual(@as(i64, 3), db.columnInt64(stmt, 0));
    try testing.expectEqual(@as(i64, 1), db.columnInt64(stmt, 1));
    try testing.expect(db.columnInt64(stmt, 2) > 0);

    const neg = database.prepare("SELECT COUNT(*) FROM retrieval_log WHERE drawer_id <= 0").?;
    defer db.finalize(neg);
    try testing.expectEqual(db.c.SQLITE_ROW, db.step(neg));
    try testing.expectEqual(@as(i64, 0), db.columnInt64(neg, 0));

    var lk = UtilityLookup.init(&database);
    defer lk.deinit();
    // Recently fetched drawer scores better (lower) than base…
    try testing.expect(lk.boost(1, 1.0) < 1.0);
    // …surfaced-but-never-fetched noise scores worse…
    try testing.expect(lk.boost(3, 1.0) > 1.0);
    // …and drawers without history stay untouched.
    try testing.expectEqual(@as(f64, 1.0), lk.boost(2, 1.0));
}

test "dream hooks: resistance and noise candidates" {
    var database = try db.Database.open(":memory:");
    defer database.close();

    // Drawer 1: surfaced 3×, fetched 3× just now → resists demotion.
    for (0..3) |_| {
        recordSurfaced(&database, 1);
        recordFetched(&database, 1);
    }
    try testing.expect(resistsDemotion(&database, 1));

    // Drawer 2: surfaced 6× and never fetched, first surfaced 20 days ago
    // (backdate one log row past the noise window).
    for (0..6) |_| recordSurfaced(&database, 2);
    database.exec(
        "INSERT INTO retrieval_log(drawer_id, event, ts) VALUES(2, 'surfaced', strftime('%s','now') - 1728000)",
    );
    try testing.expect(!resistsDemotion(&database, 2));

    // Drawer 4: surfaced 6× but only just now → too fresh to be noise.
    for (0..6) |_| recordSurfaced(&database, 4);

    const ids = try noiseCandidates(&database, 10, testing.allocator);
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqual(@as(i64, 2), ids[0]);
}
