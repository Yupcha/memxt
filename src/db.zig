// ═══════════════════════════════════════════════════════════════════
// memxt/db.zig — SQLite + sqlite-vec database engine
//
// Provides the storage backbone: verbatim text in relational tables,
// vector embeddings in sqlite-vec virtual tables, and temporal
// knowledge graph edges in SQLite.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("sqlite-vec.h");
});

const posix = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("sys/types.h");
});

/// Bump when the on-disk schema changes; add a migration branch in
/// `migrateSchema` for each step. Persisted via SQLite's `PRAGMA user_version`.
/// v2: FTS5 full-text index for hybrid keyword + vector search.
/// v3: facts, profile_entries, drawer kind/tier/lifecycle columns.
/// v4: memory clusters for hierarchical / coarse-to-fine recall.
/// v5: TurboQuant-inspired online quantized vectors (vec_quant).
pub const SCHEMA_VERSION: i64 = 5;

pub const Sqlite3 = c.sqlite3;
pub const Stmt = c.sqlite3_stmt;
const SQLITE_OK = c.SQLITE_OK;
const SQLITE_ROW = c.SQLITE_ROW;
const SQLITE_DONE = c.SQLITE_DONE;

// ── Database Handle ──

pub const Database = struct {
    handle: *Sqlite3,

    pub fn open(path: [*:0]const u8) !Database {
        // Ensure parent directory exists (e.g. ~/.memxt/ for the default palace).
        // sqlite3_open does not create intermediate directories.
        ensureParentDirs(std.mem.span(path));

        var handle: ?*Sqlite3 = null;
        if (c.sqlite3_open(path, &handle) != SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.DatabaseOpenFailed;
        }

        // Register sqlite-vec extension manually on the connection
        _ = c.sqlite3_vec_init(handle, null, null);

        var self = Database{ .handle = handle.? };

        // Performance tuning
        self.exec("PRAGMA journal_mode=WAL");
        // Multiple harnesses may point at the same palace.db concurrently. Without
        // a busy timeout a concurrent write returns SQLITE_BUSY immediately and we
        // silently drop the memory; wait up to 5s for the lock instead.
        self.exec("PRAGMA busy_timeout=5000");
        self.exec("PRAGMA synchronous=NORMAL");
        self.exec("PRAGMA cache_size=-16000"); // 16MB cache
        self.exec("PRAGMA temp_store=MEMORY");
        self.exec("PRAGMA mmap_size=536870912"); // 512MB mmap
        self.exec("PRAGMA foreign_keys=ON");

        return self;
    }

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close_v2(self.handle);
    }

    pub fn exec(self: *Database, sql: [*:0]const u8) void {
        var err_msg: [*c]u8 = null;
        var rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (rc == c.SQLITE_BUSY or rc == c.SQLITE_LOCKED) {
            // Another fleet member held the write lock past busy_timeout —
            // retry once before giving up so shared-palace writes don't drop.
            if (err_msg != null) c.sqlite3_free(err_msg);
            err_msg = null;
            rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        }
        if (rc != SQLITE_OK) {
            std.debug.print("SQL Exec Error on '{s}': {s}\n", .{ sql, err_msg });
            c.sqlite3_free(err_msg);
        }
    }

    pub fn prepare(self: *Database, sql: []const u8) ?*Stmt {
        var stmt: ?*Stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != SQLITE_OK) {
            return null;
        }
        return stmt;
    }

    pub fn lastInsertRowId(self: *Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn changes(self: *Database) i32 {
        return c.sqlite3_changes(self.handle);
    }

    pub fn errmsg(self: *Database) []const u8 {
        const msg = c.sqlite3_errmsg(self.handle);
        if (msg == null) return "unknown error";
        return std.mem.span(msg);
    }

    // ── Schema Versioning ──

    /// Read the persisted schema version (0 for a brand-new database).
    pub fn schemaVersion(self: *Database) i64 {
        const stmt = self.prepare("PRAGMA user_version") orelse return 0;
        defer finalize(stmt);
        if (step(stmt) == SQLITE_ROW) return columnInt64(stmt, 0);
        return 0;
    }

    /// Bring an existing database up to SCHEMA_VERSION. Called from
    /// createPalaceSchema after the IF-NOT-EXISTS table creation. A palace from
    /// a NEWER memxt is left untouched but flagged, so we never
    /// silently corrupt it.
    fn migrateSchema(self: *Database) void {
        const current = self.schemaVersion();
        if (current > SCHEMA_VERSION) {
            std.debug.print(
                "warn: palace schema v{d} was created by a newer memxt (this build supports v{d}); some features may not work.\n",
                .{ current, SCHEMA_VERSION },
            );
            return;
        }
        // v1 → v2: FTS5 index for hybrid keyword search (identifiers, error codes).
        if (current < 2) {
            self.ensureFtsIndex();
            // Backfill from existing drawers so upgrades regain keyword recall.
            self.exec(
                \\INSERT INTO drawers_fts(rowid, content, source_path)
                \\SELECT id, content, COALESCE(source_path, '') FROM drawers
                \\WHERE id NOT IN (SELECT rowid FROM drawers_fts)
            );
        }
        // v2 → v3: semantic core (facts, profiles) + drawer lifecycle columns.
        if (current < 3) {
            self.ensureV3Tables();
            self.ensureDrawerLifecycleColumns();
            // Backfill kind from source_type / room name heuristics.
            self.exec(
                \\UPDATE drawers SET kind = CASE
                \\  WHEN source_type IN ('memory', 'agent') THEN 'memory'
                \\  WHEN source_type IN ('decision') THEN 'decision'
                \\  WHEN source_type IN ('conversation', 'precompact-autosave', 'session') THEN 'episode'
                \\  WHEN source_type IN ('import') THEN 'memory'
                \\  ELSE 'document'
                \\END
                \\WHERE kind IS NULL OR kind = '' OR kind = 'document'
            );
            // Re-run with room-based upgrades for decisions (rooms named decisions, etc.)
            self.exec(
                \\UPDATE drawers SET kind = 'decision'
                \\WHERE id IN (
                \\  SELECT d.id FROM drawers d
                \\  JOIN rooms r ON r.id = d.room_id
                \\  WHERE lower(r.name) IN ('decisions', 'decision', 'architecture', 'adr')
                \\)
            );
        }
        // v3 → v4: hierarchical clusters.
        if (current < 4) {
            self.ensureClusterTable();
        }
        // v4 → v5: online quantized embeddings for cold/warm storage.
        if (current < 5) {
            self.ensureVecQuantTable();
        }
        if (current != SCHEMA_VERSION) {
            var buf: [64]u8 = undefined;
            const sql = std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d}", .{SCHEMA_VERSION}) catch return;
            self.exec(sql);
        }
    }

    /// Tables introduced in schema v3. Safe to call repeatedly (IF NOT EXISTS).
    pub fn ensureV3Tables(self: *Database) void {
        self.exec(
            \\CREATE TABLE IF NOT EXISTS facts (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  wing_id INTEGER NOT NULL REFERENCES wings(id) ON DELETE CASCADE,
            \\  subject TEXT NOT NULL,
            \\  predicate TEXT NOT NULL DEFAULT 'states',
            \\  object TEXT NOT NULL,
            \\  confidence REAL DEFAULT 1.0,
            \\  trust TEXT DEFAULT 'agent',
            \\  source_drawer_id INTEGER,
            \\  supersedes_id INTEGER,
            \\  valid_from INTEGER DEFAULT (strftime('%s','now')),
            \\  valid_until INTEGER,
            \\  expires_at INTEGER,
            \\  created_at INTEGER DEFAULT (strftime('%s','now'))
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_facts_wing ON facts(wing_id)");
        self.exec("CREATE INDEX IF NOT EXISTS idx_facts_subj ON facts(subject)");
        self.exec("CREATE INDEX IF NOT EXISTS idx_facts_active ON facts(wing_id, valid_until)");

        self.exec(
            \\CREATE TABLE IF NOT EXISTS profile_entries (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  wing_id INTEGER NOT NULL REFERENCES wings(id) ON DELETE CASCADE,
            \\  key TEXT NOT NULL,
            \\  value TEXT NOT NULL,
            \\  source_fact_id INTEGER,
            \\  valid_from INTEGER DEFAULT (strftime('%s','now')),
            \\  valid_until INTEGER,
            \\  created_at INTEGER DEFAULT (strftime('%s','now'))
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_profile_wing ON profile_entries(wing_id)");
        self.exec("CREATE INDEX IF NOT EXISTS idx_profile_active ON profile_entries(wing_id, valid_until)");
        self.ensureClusterTable();
    }

    pub fn ensureClusterTable(self: *Database) void {
        self.exec(
            \\CREATE TABLE IF NOT EXISTS clusters (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  wing_id INTEGER NOT NULL REFERENCES wings(id) ON DELETE CASCADE,
            \\  summary TEXT NOT NULL,
            \\  member_ids TEXT NOT NULL DEFAULT '',
            \\  drawer_id INTEGER,
            \\  created_at INTEGER DEFAULT (strftime('%s','now'))
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_clusters_wing ON clusters(wing_id)");
    }

    /// TurboQuant-style packed embeddings (online, no PQ train).
    pub fn ensureVecQuantTable(self: *Database) void {
        self.exec(
            \\CREATE TABLE IF NOT EXISTS vec_quant (
            \\  id INTEGER PRIMARY KEY,
            \\  nbits INTEGER NOT NULL DEFAULT 4,
            \\  codes BLOB NOT NULL,
            \\  residual_signs BLOB,
            \\  residual_norm REAL DEFAULT 0
            \\)
        );
    }

    /// Additive columns on drawers for kind/tier/lifecycle. SQLite ignores
    /// duplicate ALTER when we check pragma first... actually ALTER fails if
    /// column exists. We try each and ignore errors via exec (prints warn).
    /// Safer: check table_info.
    pub fn ensureDrawerLifecycleColumns(self: *Database) void {
        if (!self.columnExists("drawers", "kind")) {
            self.exec("ALTER TABLE drawers ADD COLUMN kind TEXT DEFAULT 'document'");
        }
        if (!self.columnExists("drawers", "tier")) {
            self.exec("ALTER TABLE drawers ADD COLUMN tier TEXT DEFAULT 'hot'");
        }
        if (!self.columnExists("drawers", "access_count")) {
            self.exec("ALTER TABLE drawers ADD COLUMN access_count INTEGER DEFAULT 0");
        }
        if (!self.columnExists("drawers", "last_access")) {
            self.exec("ALTER TABLE drawers ADD COLUMN last_access INTEGER");
        }
        if (!self.columnExists("drawers", "supersedes_id")) {
            self.exec("ALTER TABLE drawers ADD COLUMN supersedes_id INTEGER");
        }
        if (!self.columnExists("drawers", "expires_at")) {
            self.exec("ALTER TABLE drawers ADD COLUMN expires_at INTEGER");
        }
    }

    pub fn columnExists(self: *Database, table: []const u8, col: []const u8) bool {
        // PRAGMA table_info returns rows; we scan for name match.
        var sql_buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "PRAGMA table_info({s})", .{table}) catch return false;
        const stmt = self.prepare(sql) orelse return false;
        defer finalize(stmt);
        while (step(stmt) == SQLITE_ROW) {
            const name = columnText(stmt, 1) orelse continue;
            if (std.mem.eql(u8, name, col)) return true;
        }
        return false;
    }

    /// Create the FTS5 virtual table if missing. Safe to call repeatedly.
    pub fn ensureFtsIndex(self: *Database) void {
        self.exec(
            \\CREATE VIRTUAL TABLE IF NOT EXISTS drawers_fts USING fts5(
            \\  content,
            \\  source_path,
            \\  tokenize = 'porter unicode61'
            \\)
        );
    }

    // ── Schema Creation ──

    pub fn createPalaceSchema(self: *Database) void {
        // ── Wings (top-level containers: people, projects) ──
        self.exec(
            \\CREATE TABLE IF NOT EXISTS wings (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name TEXT NOT NULL UNIQUE,
            \\  description TEXT DEFAULT '',
            \\  wing_type TEXT DEFAULT 'project',
            \\  created_at INTEGER DEFAULT (strftime('%s','now')),
            \\  updated_at INTEGER DEFAULT (strftime('%s','now'))
            \\)
        );

        // ── Rooms (topics within a wing) ──
        self.exec(
            \\CREATE TABLE IF NOT EXISTS rooms (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  wing_id INTEGER NOT NULL REFERENCES wings(id) ON DELETE CASCADE,
            \\  name TEXT NOT NULL,
            \\  description TEXT DEFAULT '',
            \\  created_at INTEGER DEFAULT (strftime('%s','now')),
            \\  UNIQUE(wing_id, name)
            \\)
        );

        // ── Drawers (verbatim content units) ──
        self.exec(
            \\CREATE TABLE IF NOT EXISTS drawers (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  room_id INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            \\  content TEXT NOT NULL,
            \\  source_path TEXT DEFAULT '',
            \\  source_type TEXT DEFAULT 'file',
            \\  chunk_index INTEGER DEFAULT 0,
            \\  content_hash TEXT NOT NULL,
            \\  created_at INTEGER DEFAULT (strftime('%s','now'))
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_drawers_room ON drawers(room_id)");
        self.exec("CREATE INDEX IF NOT EXISTS idx_drawers_hash ON drawers(content_hash)");
        self.exec("CREATE INDEX IF NOT EXISTS idx_drawers_source ON drawers(source_path)");

        // ── Vector embeddings (sqlite-vec) ──
        self.exec(
            \\CREATE VIRTUAL TABLE IF NOT EXISTS vec_drawers USING vec0(
            \\  id INTEGER PRIMARY KEY,
            \\  embedding float[384]
            \\)
        );

        // ── Knowledge Graph (temporal entity relationships) ──
        self.exec(
            \\CREATE TABLE IF NOT EXISTS entities (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name TEXT NOT NULL UNIQUE,
            \\  entity_type TEXT DEFAULT 'concept',
            \\  first_seen INTEGER DEFAULT (strftime('%s','now')),
            \\  last_seen INTEGER DEFAULT (strftime('%s','now'))
            \\)
        );

        self.exec(
            \\CREATE TABLE IF NOT EXISTS relationships (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  subject_id INTEGER NOT NULL REFERENCES entities(id),
            \\  predicate TEXT NOT NULL,
            \\  object_id INTEGER NOT NULL REFERENCES entities(id),
            \\  confidence REAL DEFAULT 1.0,
            \\  valid_from INTEGER DEFAULT (strftime('%s','now')),
            \\  valid_until INTEGER,
            \\  source_drawer_id INTEGER REFERENCES drawers(id),
            \\  created_at INTEGER DEFAULT (strftime('%s','now'))
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_rel_subj ON relationships(subject_id)");
        self.exec("CREATE INDEX IF NOT EXISTS idx_rel_obj ON relationships(object_id)");
        self.exec("CREATE INDEX IF NOT EXISTS idx_rel_pred ON relationships(predicate)");

        // ── Agent Diaries ──
        self.exec(
            \\CREATE TABLE IF NOT EXISTS agent_diaries (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  agent_name TEXT NOT NULL,
            \\  entry TEXT NOT NULL,
            \\  session_id TEXT DEFAULT '',
            \\  created_at INTEGER DEFAULT (strftime('%s','now'))
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_diary_agent ON agent_diaries(agent_name)");

        // ── Config ──
        self.exec(
            \\CREATE TABLE IF NOT EXISTS config (
            \\  key TEXT PRIMARY KEY,
            \\  value TEXT NOT NULL DEFAULT ''
            \\)
        );

        // ── Mining sessions (dedup tracking) ──
        self.exec(
            \\CREATE TABLE IF NOT EXISTS mining_sessions (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  source_path TEXT NOT NULL,
            \\  file_count INTEGER DEFAULT 0,
            \\  drawer_count INTEGER DEFAULT 0,
            \\  started_at INTEGER DEFAULT (strftime('%s','now')),
            \\  completed_at INTEGER
            \\)
        );

        // ── FTS5 full-text index (hybrid keyword + vector search) ──
        self.ensureFtsIndex();

        // ── Semantic core (facts + profiles) + drawer lifecycle + clusters ──
        self.ensureV3Tables();
        self.ensureDrawerLifecycleColumns();
        self.ensureClusterTable();
        self.ensureVecQuantTable();

        // Stamp/upgrade the schema version last, once all tables exist.
        self.migrateSchema();
    }
};

/// Create every intermediate directory for an absolute or relative DB path.
/// Best-effort: ignores EEXIST and other races. sqlite3_open will not mkdir.
fn ensureParentDirs(path: []const u8) void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;
    var i: usize = 0;
    while (i < dir.len) : (i += 1) {
        if (dir[i] != '/') continue;
        if (i == 0) continue; // skip root "/"
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (i >= buf.len) return;
        @memcpy(buf[0..i], dir[0..i]);
        buf[i] = 0;
        _ = posix.mkdir(&buf, 0o755);
    }
    var final_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (dir.len >= final_buf.len) return;
    @memcpy(final_buf[0..dir.len], dir);
    final_buf[dir.len] = 0;
    _ = posix.mkdir(&final_buf, 0o755);
}

// ── Statement helpers ──

pub fn finalize(stmt: ?*Stmt) void {
    _ = c.sqlite3_finalize(stmt);
}

pub fn step(stmt: ?*Stmt) c_int {
    return c.sqlite3_step(stmt);
}

/// Step a write statement, retrying once when another fleet member holds the
/// write lock. busy_timeout=5000 already waits inside sqlite3_step; this
/// reset+retry covers the SQLITE_BUSY that can still surface at timeout so a
/// palace shared by parallel subagents doesn't silently drop a memory.
pub fn stepRetryBusy(stmt: ?*Stmt) c_int {
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_BUSY and rc != c.SQLITE_LOCKED) return rc;
    _ = c.sqlite3_reset(stmt);
    return c.sqlite3_step(stmt);
}

pub fn reset(stmt: ?*Stmt) void {
    _ = c.sqlite3_reset(stmt);
}

pub fn bindInt(stmt: ?*Stmt, col: c_int, val: i32) void {
    _ = c.sqlite3_bind_int(stmt, col, val);
}

pub fn bindInt64(stmt: ?*Stmt, col: c_int, val: i64) void {
    _ = c.sqlite3_bind_int64(stmt, col, val);
}

pub fn bindDouble(stmt: ?*Stmt, col: c_int, val: f64) void {
    _ = c.sqlite3_bind_double(stmt, col, val);
}

pub fn bindText(stmt: ?*Stmt, col: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), null);
}

pub fn bindBlob(stmt: ?*Stmt, col: c_int, data: []const u8) void {
    _ = c.sqlite3_bind_blob(stmt, col, data.ptr, @intCast(data.len), null);
}

pub fn columnInt(stmt: ?*Stmt, col: c_int) i32 {
    return c.sqlite3_column_int(stmt, col);
}

pub fn columnInt64(stmt: ?*Stmt, col: c_int) i64 {
    return c.sqlite3_column_int64(stmt, col);
}

pub fn columnDouble(stmt: ?*Stmt, col: c_int) f64 {
    return c.sqlite3_column_double(stmt, col);
}

pub fn columnText(stmt: ?*Stmt, col: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null or len == 0) return null;
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

pub fn columnBlob(stmt: ?*Stmt, col: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_blob(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null or len == 0) return null;
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

// ═══════════════════════════════════════════════════════════════════
// Automated Testing Suite
// ═══════════════════════════════════════════════════════════════════

test "database initialization and pragma mapping" {
    // Isolated Test Boundaries guarantees no collisions with active db natively seamlessly
    var database = Database.open(":memory:") catch |err| {
        std.debug.print("Failed to open isolated test DB: {}\n", .{err});
        return err;
    };
    defer database.close();

    database.createPalaceSchema();

    // Verify sqlite-vec loaded natively without segfaults
    const check_stmt = database.prepare("SELECT vec_version()");
    defer finalize(check_stmt);
    try std.testing.expect(check_stmt != null);

    const step_res = step(check_stmt);
    try std.testing.expectEqual(SQLITE_ROW, step_res);

    const version_str = columnText(check_stmt, 0);
    try std.testing.expect(version_str != null);
}

test "vector insertion and euclidean retrieval" {
    var database = try Database.open(":memory:");
    defer database.close();

    database.createPalaceSchema();

    // 1. Insert Synthetic Mock Vectors (Dim 384)
    var vec1: [384]f32 = undefined;
    var vec2: [384]f32 = undefined;
    for (0..384) |i| {
        vec1[i] = 0.5; // Flat line
        vec2[i] = 1.0; // Higher magnitude line
    }

    const insert_stmt = database.prepare("INSERT INTO vec_drawers(id, embedding) VALUES (?, ?)");
    defer finalize(insert_stmt);
    try std.testing.expect(insert_stmt != null);

    // Insert vec1 as ID 1
    bindInt(insert_stmt, 1, 1);
    bindBlob(insert_stmt, 2, std.mem.sliceAsBytes(vec1[0..]));
    try std.testing.expectEqual(SQLITE_DONE, step(insert_stmt));
    reset(insert_stmt);

    // Insert vec2 as ID 2
    bindInt(insert_stmt, 1, 2);
    bindBlob(insert_stmt, 2, std.mem.sliceAsBytes(vec2[0..]));
    try std.testing.expectEqual(SQLITE_DONE, step(insert_stmt));

    // 2. Query Euclidean (L2) Distance Math
    // Distance between [0.5...] and [1.0...] should mathematically rank ID 2 as functionally more distant from [0.0...] than vec1.
    // Let's search using vec1 exactly — distance to vec1 should be 0.0 mathematically. Wait, floating point math.
    const search_stmt = database.prepare(
        \\SELECT id, distance 
        \\FROM vec_drawers 
        \\WHERE embedding MATCH ? 
        \\ORDER BY distance ASC LIMIT 2
    );
    defer finalize(search_stmt);
    try std.testing.expect(search_stmt != null);

    bindBlob(search_stmt, 1, std.mem.sliceAsBytes(vec1[0..]));

    // First Result should mathematically be ID 1 with a distance extremely close to 0.0
    var step_res = step(search_stmt);
    try std.testing.expectEqual(SQLITE_ROW, step_res);
    try std.testing.expectEqual(@as(i32, 1), columnInt(search_stmt, 0));
    
    // Distance floats might have microscopic FP errors, so expect less than 0.001
    const dist1 = columnDouble(search_stmt, 1);
    try std.testing.expect(dist1 < 0.001);

    // Second Result should be ID 2
    step_res = step(search_stmt);
    try std.testing.expectEqual(SQLITE_ROW, step_res);
    try std.testing.expectEqual(@as(i32, 2), columnInt(search_stmt, 0));
}
