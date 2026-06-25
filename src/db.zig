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

/// Bump when the on-disk schema changes; add a migration branch in
/// `migrateSchema` for each step. Persisted via SQLite's `PRAGMA user_version`.
pub const SCHEMA_VERSION: i64 = 1;

pub const Sqlite3 = c.sqlite3;
pub const Stmt = c.sqlite3_stmt;
const SQLITE_OK = c.SQLITE_OK;
const SQLITE_ROW = c.SQLITE_ROW;
const SQLITE_DONE = c.SQLITE_DONE;

// ── Database Handle ──

pub const Database = struct {
    handle: *Sqlite3,

    pub fn open(path: [*:0]const u8) !Database {
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
        if (c.sqlite3_exec(self.handle, sql, null, null, &err_msg) != SQLITE_OK) {
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
        // Future: `if (current < 2) { ...migrate... }` etc.
        if (current != SCHEMA_VERSION) {
            var buf: [64]u8 = undefined;
            const sql = std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d}", .{SCHEMA_VERSION}) catch return;
            self.exec(sql);
        }
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

        // Stamp/upgrade the schema version last, once all tables exist.
        self.migrateSchema();
    }
};

// ── Statement helpers ──

pub fn finalize(stmt: ?*Stmt) void {
    _ = c.sqlite3_finalize(stmt);
}

pub fn step(stmt: ?*Stmt) c_int {
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
