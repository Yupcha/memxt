// ═══════════════════════════════════════════════════════════════════
// memxt/dreamd.zig — Dream daemon: sleep-time compute
//
// Runs the dream consolidation cycle on an interval so the agent wakes
// up to memory that was organized overnight. Adds three cycle passes on
// top of dream.zig: contradiction detection over facts, conservative
// near-duplicate drawer merges via the vector index, and precomputed
// wake-up briefs per active wing (served by wakeup.generateCached).
//
// Single instance is guarded by a pid lockfile (~/.memxt/dreamd.lock);
// SIGINT/SIGTERM shut the loop down cleanly. Cycle actions are logged
// to stderr and appended to ~/.memxt/dreamd.log.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const palace_mod = @import("palace.zig");
const dream_mod = @import("dream.zig");
const config = @import("config.zig");
const wakeup = @import("wakeup.zig");
const quant = @import("quant.zig");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("sys/stat.h");
});

pub const DaemonOptions = struct {
    /// Minutes between consolidation cycles.
    interval_mins: u32 = 60,
    /// Cosine similarity above which two hot drawers count as near-duplicates.
    similarity_threshold: f32 = 0.95,
    /// Cap on vector-index comparisons per cycle (probe × neighbor pairs).
    max_comparisons: u32 = 200,
    dream: dream_mod.DreamOptions = .{},
};

pub const CycleReport = struct {
    dream: dream_mod.DreamReport = .{},
    contradictions_found: u32 = 0,
    duplicates_merged: u32 = 0,
    briefs_cached: u32 = 0,
};

// Set from the signal handler; polled by the sleep loop.
var shutdown_requested: std.atomic.Value(bool) = .init(false);

fn onSignal(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

// ── Tables (additive — no SCHEMA_VERSION bump; IF NOT EXISTS only) ──

pub fn ensureTables(database: *db.Database) void {
    database.exec(
        \\CREATE TABLE IF NOT EXISTS contradictions (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  wing_id INTEGER NOT NULL,
        \\  fact_a_id INTEGER NOT NULL,
        \\  fact_b_id INTEGER NOT NULL,
        \\  subject TEXT NOT NULL,
        \\  predicate TEXT NOT NULL,
        \\  object_a TEXT NOT NULL,
        \\  object_b TEXT NOT NULL,
        \\  detected_at INTEGER DEFAULT (strftime('%s','now')),
        \\  UNIQUE(fact_a_id, fact_b_id)
        \\)
    );
    database.exec("CREATE INDEX IF NOT EXISTS idx_contradictions_wing ON contradictions(wing_id)");
    database.exec(
        \\CREATE TABLE IF NOT EXISTS wake_cache (
        \\  wing TEXT PRIMARY KEY,
        \\  brief TEXT NOT NULL,
        \\  generated_at INTEGER DEFAULT (strftime('%s','now'))
        \\)
    );
}

// ── Contradiction detection ──

/// Flag pairs of *active* facts in the same wing with the same subject+predicate
/// but different objects, where supersession did NOT link them. Idempotent:
/// UNIQUE(fact_a_id, fact_b_id) + OR IGNORE means a pair is flagged once.
/// Returns how many new contradictions were recorded this pass.
pub fn detectContradictions(database: *db.Database) u32 {
    const stmt = database.prepare(
        \\INSERT OR IGNORE INTO contradictions
        \\  (wing_id, fact_a_id, fact_b_id, subject, predicate, object_a, object_b)
        \\SELECT a.wing_id, a.id, b.id, a.subject, a.predicate, a.object, b.object
        \\FROM facts a
        \\JOIN facts b ON b.wing_id = a.wing_id
        \\            AND b.subject = a.subject
        \\            AND b.predicate = a.predicate
        \\            AND b.id > a.id
        \\WHERE a.valid_until IS NULL AND b.valid_until IS NULL
        \\  AND a.object <> b.object
        \\  AND COALESCE(b.supersedes_id, -1) <> a.id
        \\  AND COALESCE(a.supersedes_id, -1) <> b.id
        \\LIMIT 200
    ) orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) != db.c.SQLITE_DONE) return 0;
    return @intCast(@max(0, database.changes()));
}

pub fn countContradictions(database: *db.Database) i64 {
    const stmt = database.prepare("SELECT COUNT(*) FROM contradictions") orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return 0;
}

/// Human listing for `memxt dream --contradictions`.
pub fn printContradictions(database: *db.Database, allocator: Allocator) !void {
    ensureTables(database);
    const stmt = database.prepare(
        \\SELECT c.id, COALESCE(w.name, '?'), c.subject, c.predicate,
        \\       c.object_a, c.object_b, c.fact_a_id, c.fact_b_id, c.detected_at
        \\FROM contradictions c
        \\LEFT JOIN wings w ON w.id = c.wing_id
        \\ORDER BY c.detected_at DESC, c.id DESC
        \\LIMIT 100
    ) orelse return;
    defer db.finalize(stmt);

    var n: u32 = 0;
    while (db.step(stmt) == db.c.SQLITE_ROW) : (n += 1) {
        const line = try std.fmt.allocPrint(allocator,
            \\#{d} [{s}] {s} {s}:
            \\    "{s}"  vs  "{s}"   (facts #{d} / #{d})
            \\
        , .{
            db.columnInt64(stmt, 0),
            db.columnText(stmt, 1) orelse "?",
            db.columnText(stmt, 2) orelse "",
            db.columnText(stmt, 3) orelse "",
            db.columnText(stmt, 4) orelse "",
            db.columnText(stmt, 5) orelse "",
            db.columnInt64(stmt, 6),
            db.columnInt64(stmt, 7),
        });
        defer allocator.free(line);
        std.debug.print("{s}", .{line});
    }
    if (n == 0) {
        std.debug.print("No contradictions on record. 🌙\n", .{});
    } else {
        std.debug.print("\n{d} contradiction{s}. Resolve by storing the correct fact (supersession closes the loser).\n", .{ n, if (n == 1) "" else "s" });
    }
}

// ── Near-duplicate merge ──

pub const MergeCandidate = struct {
    /// Newer drawer — kept, gains the pointer line.
    keep_id: i64,
    /// Older drawer — demoted to cold (never deleted).
    demote_id: i64,
    cosine: f32,
};

/// Find near-duplicate hot drawer pairs *within a wing* via k-NN probes on the
/// vector index (never O(n²)). Work is bounded by `max_comparisons` probe ×
/// neighbor pairs. Each drawer appears in at most one returned candidate.
pub fn findMergeCandidates(
    database: *db.Database,
    threshold: f32,
    max_comparisons: u32,
    allocator: Allocator,
) ![]MergeCandidate {
    var out: std.ArrayListUnmanaged(MergeCandidate) = .empty;
    errdefer out.deinit(allocator);
    if (max_comparisons == 0) return out.toOwnedSlice(allocator);

    // Drawers already claimed by a pair this pass — merge conservatively,
    // one partner each.
    var claimed: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer claimed.deinit(allocator);

    // Probe the most recent hot drawers; each probe costs a handful of
    // neighbor comparisons through the index.
    const probes = database.prepare(
        \\SELECT d.id FROM drawers d
        \\JOIN vec_drawers v ON v.id = d.id
        \\WHERE COALESCE(d.tier, 'hot') = 'hot'
        \\ORDER BY d.created_at DESC, d.id DESC
        \\LIMIT ?
    ) orelse return out.toOwnedSlice(allocator);
    defer db.finalize(probes);
    db.bindInt64(probes, 1, max_comparisons); // ≥ enough probes for the budget

    var comparisons: u32 = 0;
    while (db.step(probes) == db.c.SQLITE_ROW) {
        if (comparisons >= max_comparisons) break;
        const probe_id = db.columnInt64(probes, 0);
        if (claimed.contains(probe_id)) continue;

        var probe_emb: [quant.DIM]f32 = undefined;
        if (!loadEmbedding(database, probe_id, &probe_emb)) continue;
        const probe_meta = drawerMeta(database, probe_id) orelse continue;

        // Nearest neighbors through the index (k small; excludes nothing, so
        // the probe itself comes back at distance 0 and is skipped).
        const knn = database.prepare(
            \\SELECT id FROM vec_drawers
            \\WHERE embedding MATCH ? AND k = ?
            \\ORDER BY distance ASC
        ) orelse continue;
        defer db.finalize(knn);
        db.bindBlob(knn, 1, std.mem.sliceAsBytes(probe_emb[0..]));
        db.bindInt(knn, 2, 4);

        while (db.step(knn) == db.c.SQLITE_ROW) {
            if (comparisons >= max_comparisons) break;
            const other_id = db.columnInt64(knn, 0);
            if (other_id == probe_id) continue;
            comparisons += 1;
            if (claimed.contains(other_id)) continue;

            const other_meta = drawerMeta(database, other_id) orelse continue;
            if (other_meta.wing_id != probe_meta.wing_id) continue;
            if (!other_meta.hot) continue;

            var other_emb: [quant.DIM]f32 = undefined;
            if (!loadEmbedding(database, other_id, &other_emb)) continue;
            const cos = cosineF32(probe_emb[0..], other_emb[0..]);
            if (cos < threshold) continue;

            // Keep the newer drawer (created_at, id tie-break); demote the older.
            const probe_newer = probe_meta.created_at > other_meta.created_at or
                (probe_meta.created_at == other_meta.created_at and probe_id > other_id);
            try out.append(allocator, .{
                .keep_id = if (probe_newer) probe_id else other_id,
                .demote_id = if (probe_newer) other_id else probe_id,
                .cosine = cos,
            });
            try claimed.put(allocator, probe_id, {});
            try claimed.put(allocator, other_id, {});
            break; // one partner per probe — conservative
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Merge near-duplicates: append a pointer line to the kept (newer) drawer and
/// demote the older one to cold (quantized vector + FTS retained, never deleted).
/// Returns the number of pairs merged.
pub fn mergeNearDuplicates(
    database: *db.Database,
    threshold: f32,
    max_comparisons: u32,
    allocator: Allocator,
) !u32 {
    const candidates = try findMergeCandidates(database, threshold, max_comparisons, allocator);
    defer allocator.free(candidates);

    var pal = palace_mod.Palace.init(database, allocator);
    var merged: u32 = 0;
    for (candidates) |cand| {
        const stmt = database.prepare(
            \\UPDATE drawers
            \\SET content = content || char(10) || '(merged duplicate of drawer ' || ? || ')'
            \\WHERE id = ?
        ) orelse continue;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, cand.demote_id);
        db.bindInt64(stmt, 2, cand.keep_id);
        if (db.step(stmt) != db.c.SQLITE_DONE) continue;

        refreshFtsRow(database, cand.keep_id);
        pal.demoteToCold(cand.demote_id) catch continue;
        merged += 1;
    }
    return merged;
}

const DrawerMeta = struct {
    wing_id: i64,
    created_at: i64,
    hot: bool,
};

fn drawerMeta(database: *db.Database, drawer_id: i64) ?DrawerMeta {
    const stmt = database.prepare(
        \\SELECT r.wing_id, d.created_at, COALESCE(d.tier, 'hot')
        \\FROM drawers d
        \\JOIN rooms r ON r.id = d.room_id
        \\WHERE d.id = ?
    ) orelse return null;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, drawer_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const tier = db.columnText(stmt, 2) orelse "hot";
    return .{
        .wing_id = db.columnInt64(stmt, 0),
        .created_at = db.columnInt64(stmt, 1),
        .hot = std.mem.eql(u8, tier, "hot"),
    };
}

fn loadEmbedding(database: *db.Database, drawer_id: i64, out: *[quant.DIM]f32) bool {
    const stmt = database.prepare("SELECT embedding FROM vec_drawers WHERE id = ?") orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, drawer_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return false;
    const blob = db.columnBlob(stmt, 0) orelse return false;
    if (blob.len < quant.DIM * @sizeOf(f32)) return false;
    const src: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, blob[0 .. quant.DIM * @sizeOf(f32)]));
    @memcpy(out[0..], src[0..quant.DIM]);
    return true;
}

fn cosineF32(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (a, b) |x, y| {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    const denom = @sqrt(na) * @sqrt(nb);
    if (denom <= 0) return 0;
    return dot / denom;
}

/// Re-sync the FTS row for a drawer whose content changed (best-effort).
fn refreshFtsRow(database: *db.Database, drawer_id: i64) void {
    {
        const del = database.prepare("DELETE FROM drawers_fts WHERE rowid = ?") orelse return;
        defer db.finalize(del);
        db.bindInt64(del, 1, drawer_id);
        _ = db.step(del);
    }
    const ins = database.prepare(
        \\INSERT INTO drawers_fts(rowid, content, source_path)
        \\SELECT id, content, COALESCE(source_path, '') FROM drawers WHERE id = ?
    ) orelse return;
    defer db.finalize(ins);
    db.bindInt64(ins, 1, drawer_id);
    _ = db.step(ins);
}

// ── Precomputed wake briefs ──

/// Render the wake-up brief for every active wing (wings with drawers) plus
/// the global (all-wings) brief under the '' key, into wake_cache.
pub fn cacheWakeBriefs(database: *db.Database, allocator: Allocator) !u32 {
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    {
        const stmt = database.prepare(
            \\SELECT DISTINCT w.name FROM wings w
            \\JOIN rooms r ON r.wing_id = w.id
            \\JOIN drawers d ON d.room_id = r.id
            \\LIMIT 32
        ) orelse return 0;
        defer db.finalize(stmt);
        while (db.step(stmt) == db.c.SQLITE_ROW) {
            const name = db.columnText(stmt, 0) orelse continue;
            try names.append(allocator, try allocator.dupe(u8, name));
        }
    }

    var cached: u32 = 0;
    for (names.items) |name| {
        const brief = wakeup.generate(database, name, allocator) catch continue;
        defer allocator.free(brief);
        if (upsertWakeCache(database, name, brief)) cached += 1;
    }
    // Global brief (no wing filter) under the empty key.
    if (wakeup.generate(database, null, allocator)) |brief| {
        defer allocator.free(brief);
        if (upsertWakeCache(database, "", brief)) cached += 1;
    } else |_| {}
    return cached;
}

fn upsertWakeCache(database: *db.Database, wing: []const u8, brief: []const u8) bool {
    const stmt = database.prepare(
        "INSERT OR REPLACE INTO wake_cache(wing, brief, generated_at) VALUES(?, ?, strftime('%s','now'))",
    ) orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, wing);
    db.bindText(stmt, 2, brief);
    return db.step(stmt) == db.c.SQLITE_DONE;
}

// ── Cycle ──

pub fn runCycle(database: *db.Database, opts: DaemonOptions, allocator: Allocator) !CycleReport {
    ensureTables(database);
    var report = CycleReport{};
    report.dream = try dream_mod.run(database, opts.dream, allocator);
    report.contradictions_found = detectContradictions(database);
    if (!opts.dream.dry_run) {
        report.duplicates_merged = try mergeNearDuplicates(
            database,
            opts.similarity_threshold,
            opts.max_comparisons,
            allocator,
        );
        report.briefs_cached = try cacheWakeBriefs(database, allocator);
    }
    return report;
}

// ── Lockfile (single-instance guard) ──

pub const LockError = error{ AlreadyRunning, LockFailed };

/// Create the pid lockfile exclusively. If it already exists and its pid is
/// alive → AlreadyRunning; a stale lock (dead pid / garbage) is reclaimed.
pub fn acquireLock(path: [*:0]const u8) LockError!void {
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        const fd = c.open(path, c.O_CREAT | c.O_EXCL | c.O_WRONLY, @as(c_uint, 0o644));
        if (fd >= 0) {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}\n", .{c.getpid()}) catch "";
            _ = c.write(fd, s.ptr, s.len);
            _ = c.close(fd);
            return;
        }
        // Lock exists (or open failed) — live owner?
        if (lockOwnerPid(path)) |pid| {
            if (pidAlive(pid)) return error.AlreadyRunning;
        }
        // Stale or unreadable: clear and retry once.
        _ = c.unlink(path);
    }
    return error.LockFailed;
}

pub fn releaseLock(path: [*:0]const u8) void {
    _ = c.unlink(path);
}

/// Pid recorded in the lockfile, or null if the file is missing/garbled.
pub fn lockOwnerPid(path: [*:0]const u8) ?i32 {
    const f = c.fopen(path, "r") orelse return null;
    defer _ = c.fclose(f);
    var buf: [32]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    const s = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
    return std.fmt.parseInt(i32, s, 10) catch null;
}

fn pidAlive(pid: i32) bool {
    if (pid <= 0) return false;
    return c.kill(pid, 0) == 0;
}

fn lockFilePath(buf: *[std.fs.max_path_bytes]u8) ?[:0]const u8 {
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.memxt/dreamd.lock", .{std.mem.span(home)}) catch null;
}

// ── Logging ──

fn logLine(allocator: Allocator, comptime fmt: []const u8, args: anytype) void {
    const body = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(body);
    const line = std.fmt.allocPrint(allocator, "[dreamd ts={d}] {s}", .{ std.time.timestamp(), body }) catch return;
    defer allocator.free(line);
    std.debug.print("{s}\n", .{line});
    appendLogFile(line);
}

fn appendLogFile(msg: []const u8) void {
    const home = c.getenv("HOME") orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/.memxt/dreamd.log", .{std.mem.span(home)}) catch return;
    const f = c.fopen(path.ptr, "a") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(msg.ptr, 1, msg.len, f);
    _ = c.fwrite("\n", 1, 1, f);
}

// ── Config stamps (last-cycle summary for --status / cache freshness) ──

fn setConfig(database: *db.Database, key: []const u8, value: []const u8) void {
    const stmt = database.prepare("INSERT OR REPLACE INTO config(key, value) VALUES(?, ?)") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, value);
    _ = db.step(stmt);
}

fn getConfigAlloc(database: *db.Database, key: []const u8, allocator: Allocator) ?[]u8 {
    const stmt = database.prepare("SELECT value FROM config WHERE key = ?") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const v = db.columnText(stmt, 0) orelse return null;
    return allocator.dupe(u8, v) catch null;
}

fn persistCycleSummary(database: *db.Database, report: CycleReport, allocator: Allocator) void {
    const summary = std.fmt.allocPrint(
        allocator,
        "expired={d} demoted={d} clusters={d} contradictions={d} merged={d} briefs={d} hot={d}",
        .{
            report.dream.facts_expired,
            report.dream.demoted,
            report.dream.clusters_built,
            report.contradictions_found,
            report.duplicates_merged,
            report.briefs_cached,
            report.dream.hot_after,
        },
    ) catch return;
    defer allocator.free(summary);
    setConfig(database, "dreamd_last_summary", summary);

    var ts_buf: [24]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch return;
    setConfig(database, "dreamd_last_cycle_at", ts);
}

// ── Daemon loop ──

pub fn runDaemon(cfg: *const config.Config, opts: DaemonOptions, allocator: Allocator) !void {
    // ~/.memxt must exist before the lockfile can (db open also mkdirs, but
    // the lock is taken first).
    if (c.getenv("HOME")) |home| {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrintZ(&dir_buf, "{s}/.memxt", .{std.mem.span(home)})) |dir| {
            _ = c.mkdir(dir.ptr, 0o755);
        } else |_| {}
    }

    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = lockFilePath(&lock_buf) orelse {
        std.debug.print("dreamd: HOME not set; cannot place lockfile.\n", .{});
        return;
    };
    acquireLock(lock_path.ptr) catch |err| {
        if (err == error.AlreadyRunning) {
            const pid = lockOwnerPid(lock_path.ptr) orelse 0;
            std.debug.print("dreamd already running (pid {d}, lock {s}).\n", .{ pid, lock_path });
            return;
        }
        std.debug.print("dreamd: could not acquire lock at {s}.\n", .{lock_path});
        return;
    };
    defer releaseLock(lock_path.ptr);

    shutdown_requested.store(false, .release);
    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);

    var database = try db.Database.open(cfg.database_path.ptr);
    defer database.close();
    database.createPalaceSchema();
    ensureTables(&database);

    // Stamp the interval so wakeup.generateCached knows what "fresh" means.
    var mins_buf: [16]u8 = undefined;
    if (std.fmt.bufPrint(&mins_buf, "{d}", .{opts.interval_mins})) |mins| {
        setConfig(&database, "dreamd_interval_mins", mins);
    } else |_| {}

    logLine(allocator, "started pid={d} interval={d}m db={s}", .{ c.getpid(), opts.interval_mins, cfg.database_path });

    while (!shutdown_requested.load(.acquire)) {
        if (runCycle(&database, opts, allocator)) |report| {
            persistCycleSummary(&database, report, allocator);
            logLine(allocator, "cycle: expired={d} demoted={d} clusters={d} contradictions={d} merged={d} briefs={d} hot={d}→{d}", .{
                report.dream.facts_expired,
                report.dream.demoted,
                report.dream.clusters_built,
                report.contradictions_found,
                report.duplicates_merged,
                report.briefs_cached,
                report.dream.hot_before,
                report.dream.hot_after,
            });
        } else |err| {
            logLine(allocator, "cycle failed: {s}", .{@errorName(err)});
        }

        // Sleep in 1s slices so SIGINT/SIGTERM stop us within a second.
        const interval_secs: u64 = @as(u64, opts.interval_mins) * 60;
        var slept: u64 = 0;
        while (slept < interval_secs and !shutdown_requested.load(.acquire)) : (slept += 1) {
            _ = c.sleep(1);
        }
    }

    logLine(allocator, "stopped pid={d} (signal)", .{c.getpid()});
}

/// `memxt dream --status` — daemon liveness (from the lockfile) + last cycle.
pub fn printStatus(cfg: *const config.Config, allocator: Allocator) !void {
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (lockFilePath(&lock_buf)) |lock_path| {
        if (lockOwnerPid(lock_path.ptr)) |pid| {
            if (pidAlive(pid)) {
                std.debug.print("dreamd: running (pid {d})\n", .{pid});
            } else {
                std.debug.print("dreamd: not running (stale lockfile, pid {d} is gone)\n", .{pid});
            }
        } else {
            std.debug.print("dreamd: not running\n", .{});
        }
        std.debug.print("lockfile: {s}\n", .{lock_path});
    } else {
        std.debug.print("dreamd: HOME not set; no lockfile location.\n", .{});
    }

    var database = try db.Database.open(cfg.database_path.ptr);
    defer database.close();
    database.createPalaceSchema();
    ensureTables(&database);

    if (getConfigAlloc(&database, "dreamd_last_cycle_at", allocator)) |ts| {
        defer allocator.free(ts);
        std.debug.print("last cycle: {s} (unix)\n", .{ts});
    } else {
        std.debug.print("last cycle: never\n", .{});
    }
    if (getConfigAlloc(&database, "dreamd_last_summary", allocator)) |summary| {
        defer allocator.free(summary);
        std.debug.print("last summary: {s}\n", .{summary});
    }
    if (getConfigAlloc(&database, "dreamd_interval_mins", allocator)) |mins| {
        defer allocator.free(mins);
        std.debug.print("interval: {s}m\n", .{mins});
    }
    std.debug.print("contradictions on record: {d}\n", .{countContradictions(&database)});
}

// ═══════════════════════════════════════════════════════════════════
// Automated Testing Suite
// ═══════════════════════════════════════════════════════════════════

fn testInsertFact(
    database: *db.Database,
    wing_id: i64,
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    supersedes_id: ?i64,
    valid_until: ?i64,
) i64 {
    const stmt = database.prepare(
        \\INSERT INTO facts(wing_id, subject, predicate, object, supersedes_id, valid_until)
        \\VALUES(?, ?, ?, ?, ?, ?)
    ) orelse return -1;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, wing_id);
    db.bindText(stmt, 2, subject);
    db.bindText(stmt, 3, predicate);
    db.bindText(stmt, 4, object);
    if (supersedes_id) |sid| db.bindInt64(stmt, 5, sid) else _ = db.c.sqlite3_bind_null(stmt, 5);
    if (valid_until) |vu| db.bindInt64(stmt, 6, vu) else _ = db.c.sqlite3_bind_null(stmt, 6);
    _ = db.step(stmt);
    return database.lastInsertRowId();
}

test "contradiction detection flags unlinked conflicting facts only" {
    const allocator = std.testing.allocator;
    var database = try db.Database.open(":memory:");
    defer database.close();
    database.createPalaceSchema();
    ensureTables(&database);

    var pal = palace_mod.Palace.init(&database, allocator);
    const wing_id = try pal.createWing("testwing", "", "project");

    // 1) Two active facts, same subject+predicate, different objects, no
    //    supersession link → contradiction.
    _ = testInsertFact(&database, wing_id, "project", "uses", "postgres", null, null);
    _ = testInsertFact(&database, wing_id, "project", "uses", "sqlite", null, null);

    // 2) Conflicting pair, but supersession DID link them → not a contradiction.
    const old_id = testInsertFact(&database, wing_id, "project", "prefers", "tabs", null, null);
    _ = testInsertFact(&database, wing_id, "project", "prefers", "spaces", old_id, null);

    // 3) Same object → agreement, not a contradiction.
    _ = testInsertFact(&database, wing_id, "team", "chose", "zig", null, null);
    _ = testInsertFact(&database, wing_id, "team", "chose", "zig", null, null);

    // 4) Conflict, but one side is already closed → not active, skipped.
    _ = testInsertFact(&database, wing_id, "ci", "uses", "github", null, 1);
    _ = testInsertFact(&database, wing_id, "ci", "uses", "buildkite", null, null);

    const found = detectContradictions(&database);
    try std.testing.expectEqual(@as(u32, 1), found);
    try std.testing.expectEqual(@as(i64, 1), countContradictions(&database));

    // Idempotent: a second pass records nothing new.
    try std.testing.expectEqual(@as(u32, 0), detectContradictions(&database));
    try std.testing.expectEqual(@as(i64, 1), countContradictions(&database));
}

test "merge candidate selection respects threshold, wing scope, and comparison cap" {
    const allocator = std.testing.allocator;
    var database = try db.Database.open(":memory:");
    defer database.close();
    database.createPalaceSchema();
    ensureTables(&database);

    var pal = palace_mod.Palace.init(&database, allocator);
    const wing_a = try pal.createWing("wing-a", "", "project");
    const wing_b = try pal.createWing("wing-b", "", "project");
    const room_a = try pal.createRoom(wing_a, "notes", "");
    const room_b = try pal.createRoom(wing_b, "notes", "");

    // Two near-identical vectors in wing A (cosine 1.0) + one orthogonal.
    var vec_dup: [quant.DIM]f32 = @splat(0.0);
    vec_dup[0] = 1.0;
    var vec_other: [quant.DIM]f32 = @splat(0.0);
    vec_other[1] = 1.0;

    const id_old = try pal.insertDrawerKind(room_a, "we use sqlite for storage", "t", "memory", 0, vec_dup[0..], "memory", null);
    const id_new = try pal.insertDrawerKind(room_a, "we use sqlite for storage!", "t", "memory", 0, vec_dup[0..], "memory", null);
    _ = try pal.insertDrawerKind(room_a, "unrelated orthogonal note", "t", "memory", 0, vec_other[0..], "memory", null);
    // Same vector but in wing B — must NOT pair across wings.
    _ = try pal.insertDrawerKind(room_b, "we use sqlite (other wing)", "t", "memory", 0, vec_dup[0..], "memory", null);

    const candidates = try findMergeCandidates(&database, 0.95, 200, allocator);
    defer allocator.free(candidates);

    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expect(candidates[0].cosine >= 0.95);
    // Same-second inserts: newer decided by higher id.
    try std.testing.expectEqual(id_new, candidates[0].keep_id);
    try std.testing.expectEqual(id_old, candidates[0].demote_id);

    // Comparison budget of zero → no work at all.
    const none = try findMergeCandidates(&database, 0.95, 0, allocator);
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // Applying the merge keeps the newer drawer (with pointer line) and
    // demotes — never deletes — the older one.
    const merged = try mergeNearDuplicates(&database, 0.95, 200, allocator);
    try std.testing.expectEqual(@as(u32, 1), merged);

    var detail = (try pal.getDrawer(id_new, allocator)) orelse return error.TestUnexpectedResult;
    defer detail.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, detail.content, "(merged duplicate of drawer ") != null);

    var old_detail = (try pal.getDrawer(id_old, allocator)) orelse return error.TestUnexpectedResult;
    defer old_detail.deinit(allocator);

    const tier_stmt = database.prepare("SELECT COALESCE(tier,'hot') FROM drawers WHERE id = ?") orelse return error.TestUnexpectedResult;
    defer db.finalize(tier_stmt);
    db.bindInt64(tier_stmt, 1, id_old);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.step(tier_stmt));
    try std.testing.expectEqualStrings("cold", db.columnText(tier_stmt, 0) orelse "");
}

test "lockfile enforces single instance and reclaims stale locks" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/memxt-dreamd-test-{d}.lock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    // First acquire wins and records our (live) pid.
    try acquireLock(path.ptr);
    try std.testing.expectEqual(@as(i32, @intCast(c.getpid())), lockOwnerPid(path.ptr).?);

    // Second acquire sees a live owner → AlreadyRunning.
    try std.testing.expectError(error.AlreadyRunning, acquireLock(path.ptr));

    // Release, then re-acquire succeeds.
    releaseLock(path.ptr);
    try acquireLock(path.ptr);
    releaseLock(path.ptr);

    // Stale lock (dead/impossible pid) is reclaimed.
    {
        const f = c.fopen(path.ptr, "w") orelse return error.TestUnexpectedResult;
        const stale = "99999999\n";
        _ = c.fwrite(stale.ptr, 1, stale.len, f);
        _ = c.fclose(f);
    }
    try acquireLock(path.ptr);
    try std.testing.expectEqual(@as(i32, @intCast(c.getpid())), lockOwnerPid(path.ptr).?);
    releaseLock(path.ptr);
}

test "wake cache upsert and freshness lookup" {
    const allocator = std.testing.allocator;
    var database = try db.Database.open(":memory:");
    defer database.close();
    database.createPalaceSchema();
    ensureTables(&database);

    try std.testing.expect(upsertWakeCache(&database, "wing-x", "cached brief body"));
    const brief = wakeup.cachedBriefForTest(&database, "wing-x", allocator) orelse return error.TestUnexpectedResult;
    defer allocator.free(brief);
    try std.testing.expectEqualStrings("cached brief body", brief);

    // Expired entry (generated_at far in the past) is not served.
    database.exec("UPDATE wake_cache SET generated_at = 0 WHERE wing = 'wing-x'");
    try std.testing.expect(wakeup.cachedBriefForTest(&database, "wing-x", allocator) == null);
}
