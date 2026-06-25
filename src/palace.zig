// ═══════════════════════════════════════════════════════════════════
// memxt/palace.zig — Palace Engine
//
// The core "memory palace" abstraction. Content is organized into:
//   Wing  → A project, person, or top-level domain
//   Room  → A topic within a wing
//   Drawer → A verbatim chunk of content with its embedding
//
// All content is stored verbatim — no summarization, no extraction.
// Retrieval is via semantic similarity (sqlite-vec) + hybrid scoring.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;

// Serializes write sequences that depend on lastInsertRowId(). The concurrent
// miner inserts a drawer row then reads the new rowid to attach its embedding;
// without this lock two threads interleave and bind embeddings to the WRONG
// drawer id, silently corrupting semantic search. The lock makes the
// content-insert → rowid → vector-insert sequence atomic.
var write_lock: std.atomic.Value(bool) = .init(false);

fn lockWrites() void {
    while (write_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}
fn unlockWrites() void {
    write_lock.store(false, .release);
}

// ── Data Types ──

pub const Wing = struct {
    id: i64,
    name: []const u8,
    description: []const u8,
    wing_type: []const u8,
    created_at: i64,
};

pub const Room = struct {
    id: i64,
    wing_id: i64,
    name: []const u8,
    description: []const u8,
};

pub const Drawer = struct {
    id: i64,
    room_id: i64,
    content: []const u8,
    source_path: []const u8,
    source_type: []const u8,
    content_hash: []const u8,
    created_at: i64,
};

pub const SearchResult = struct {
    drawer_id: i64,
    content: []const u8,
    source_path: []const u8,
    wing_name: []const u8,
    room_name: []const u8,
    distance: f64,
    score: f64, // hybrid score (lower = better match)
    created_at: i64,
};

// ── Palace Engine ──

pub const Palace = struct {
    database: *db.Database,
    allocator: Allocator,

    pub fn init(database: *db.Database, allocator: Allocator) Palace {
        return .{
            .database = database,
            .allocator = allocator,
        };
    }

    // ── Wing Operations ──

    pub fn createWing(self: *Palace, name: []const u8, description: []const u8, wing_type: []const u8) !i64 {
        const stmt = self.database.prepare(
            "INSERT OR IGNORE INTO wings(name, description, wing_type) VALUES(?, ?, ?)",
        ) orelse return error.PrepareFailed;
        defer db.finalize(stmt);

        db.bindText(stmt, 1, name);
        db.bindText(stmt, 2, description);
        db.bindText(stmt, 3, wing_type);

        if (db.step(stmt) != db.c.SQLITE_DONE) return error.InsertFailed;

        // If OR IGNORE fired (duplicate), look up existing ID
        const rowid = self.database.lastInsertRowId();
        if (rowid == 0) {
            return self.getWingId(name) orelse error.NotFound;
        }
        return rowid;
    }

    pub fn getWingId(self: *Palace, name: []const u8) ?i64 {
        const stmt = self.database.prepare("SELECT id FROM wings WHERE name = ?") orelse return null;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, name);
        if (db.step(stmt) == db.c.SQLITE_ROW) {
            return db.columnInt64(stmt, 0);
        }
        return null;
    }

    pub fn listWings(self: *Palace, allocator: Allocator) ![]Wing {
        const stmt = self.database.prepare(
            "SELECT id, name, description, wing_type, created_at FROM wings ORDER BY name",
        ) orelse return error.PrepareFailed;
        defer db.finalize(stmt);

        var wings: std.ArrayListUnmanaged(Wing) = .empty;
        errdefer wings.deinit(allocator);

        while (db.step(stmt) == db.c.SQLITE_ROW) {
            try wings.append(allocator, .{
                .id = db.columnInt64(stmt, 0),
                .name = try allocator.dupe(u8, db.columnText(stmt, 1) orelse ""),
                .description = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
                .wing_type = try allocator.dupe(u8, db.columnText(stmt, 3) orelse "project"),
                .created_at = db.columnInt64(stmt, 4),
            });
        }
        return wings.toOwnedSlice(allocator);
    }

    // ── Room Operations ──

    pub fn createRoom(self: *Palace, wing_id: i64, name: []const u8, description: []const u8) !i64 {
        const stmt = self.database.prepare(
            "INSERT OR IGNORE INTO rooms(wing_id, name, description) VALUES(?, ?, ?)",
        ) orelse return error.PrepareFailed;
        defer db.finalize(stmt);

        db.bindInt64(stmt, 1, wing_id);
        db.bindText(stmt, 2, name);
        db.bindText(stmt, 3, description);

        if (db.step(stmt) != db.c.SQLITE_DONE) return error.InsertFailed;

        const rowid = self.database.lastInsertRowId();
        if (rowid == 0) {
            return self.getRoomId(wing_id, name) orelse error.NotFound;
        }
        return rowid;
    }

    pub fn getRoomId(self: *Palace, wing_id: i64, name: []const u8) ?i64 {
        const stmt = self.database.prepare(
            "SELECT id FROM rooms WHERE wing_id = ? AND name = ?",
        ) orelse return null;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, wing_id);
        db.bindText(stmt, 2, name);
        if (db.step(stmt) == db.c.SQLITE_ROW) {
            return db.columnInt64(stmt, 0);
        }
        return null;
    }

    pub fn listRooms(self: *Palace, wing_id: i64, allocator: Allocator) ![]Room {
        const stmt = self.database.prepare(
            "SELECT id, wing_id, name, description FROM rooms WHERE wing_id = ? ORDER BY name",
        ) orelse return error.PrepareFailed;
        defer db.finalize(stmt);

        db.bindInt64(stmt, 1, wing_id);

        var rooms: std.ArrayListUnmanaged(Room) = .empty;
        errdefer rooms.deinit(allocator);

        while (db.step(stmt) == db.c.SQLITE_ROW) {
            try rooms.append(allocator, .{
                .id = db.columnInt64(stmt, 0),
                .wing_id = db.columnInt64(stmt, 1),
                .name = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
                .description = try allocator.dupe(u8, db.columnText(stmt, 3) orelse ""),
            });
        }
        return rooms.toOwnedSlice(allocator);
    }

    // ── Drawer Operations ──

    pub fn insertDrawer(
        self: *Palace,
        room_id: i64,
        content: []const u8,
        source_path: []const u8,
        source_type: []const u8,
        chunk_index: i32,
        embedding: []const f32,
    ) !i64 {
        // Compute content hash for dedup
        var hash_buf: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &hash_buf, .{});
        var hash_hex: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&hash_hex, "{s}", .{std.fmt.bytesToHex(hash_buf, .lower)}) catch return error.HashFailed;

        // Hold the write lock across dedup-check → insert → rowid → vec-insert so
        // the rowid we read is unambiguously the row we just inserted, even when
        // the miner calls this concurrently from multiple tasks.
        lockWrites();
        defer unlockWrites();

        // Check dedup
        {
            const check = self.database.prepare("SELECT id FROM drawers WHERE content_hash = ?") orelse return error.PrepareFailed;
            defer db.finalize(check);
            db.bindText(check, 1, hex);
            if (db.step(check) == db.c.SQLITE_ROW) {
                return db.columnInt64(check, 0); // Already exists
            }
        }

        // Insert content
        const stmt = self.database.prepare(
            "INSERT INTO drawers(room_id, content, source_path, source_type, chunk_index, content_hash) VALUES(?, ?, ?, ?, ?, ?)",
        ) orelse return error.PrepareFailed;
        defer db.finalize(stmt);

        db.bindInt64(stmt, 1, room_id);
        db.bindText(stmt, 2, content);
        db.bindText(stmt, 3, source_path);
        db.bindText(stmt, 4, source_type);
        db.bindInt(stmt, 5, chunk_index);
        db.bindText(stmt, 6, hex);

        if (db.step(stmt) != db.c.SQLITE_DONE) return error.InsertFailed;

        const drawer_id = self.database.lastInsertRowId();

        // Insert vector embedding
        if (embedding.len > 0) {
            const vec_stmt = self.database.prepare(
                "INSERT INTO vec_drawers(id, embedding) VALUES(?, ?)",
            ) orelse return error.PrepareFailed;
            defer db.finalize(vec_stmt);

            db.bindInt64(vec_stmt, 1, drawer_id);
            db.bindBlob(vec_stmt, 2, std.mem.sliceAsBytes(embedding));

            _ = db.step(vec_stmt);
        }

        return drawer_id;
    }

    /// Semantic search across all drawers with hybrid scoring
    pub fn search(self: *Palace, query_embedding: []const f32, limit: i32, allocator: Allocator) ![]SearchResult {
        // Vector similarity search via sqlite-vec
        const sql =
            \\SELECT v.id, v.distance,
            \\       d.content, d.source_path, d.created_at,
            \\       r.name as room_name,
            \\       w.name as wing_name
            \\FROM vec_drawers v
            \\JOIN drawers d ON d.id = v.id
            \\JOIN rooms r ON r.id = d.room_id
            \\JOIN wings w ON w.id = r.wing_id
            \\WHERE v.embedding MATCH ? AND k = ?
            \\ORDER BY v.distance ASC
        ;

        const stmt = self.database.prepare(sql) orelse {
            std.debug.print("Prepare Failed: {s}\n", .{self.database.errmsg()});
            return error.PrepareFailed;
        };
        defer db.finalize(stmt);

        db.bindBlob(stmt, 1, std.mem.sliceAsBytes(query_embedding));
        db.bindInt(stmt, 2, limit);

        var results: std.ArrayListUnmanaged(SearchResult) = .empty;
        errdefer results.deinit(allocator);

        while (db.step(stmt) == db.c.SQLITE_ROW) {
            const distance = db.columnDouble(stmt, 1);

            try results.append(allocator, .{
                .drawer_id = db.columnInt64(stmt, 0),
                .content = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
                .source_path = try allocator.dupe(u8, db.columnText(stmt, 3) orelse ""),
                .created_at = db.columnInt64(stmt, 4),
                .room_name = try allocator.dupe(u8, db.columnText(stmt, 5) orelse ""),
                .wing_name = try allocator.dupe(u8, db.columnText(stmt, 6) orelse ""),
                .distance = distance,
                .score = distance, // Base score = vector distance
            });
        }

        return results.toOwnedSlice(allocator);
    }

    /// Count total drawers in the palace
    pub fn drawerCount(self: *Palace) i64 {
        const stmt = self.database.prepare("SELECT COUNT(*) FROM drawers") orelse return 0;
        defer db.finalize(stmt);
        if (db.step(stmt) == db.c.SQLITE_ROW) {
            return db.columnInt64(stmt, 0);
        }
        return 0;
    }

    /// Count total wings
    pub fn wingCount(self: *Palace) i64 {
        const stmt = self.database.prepare("SELECT COUNT(*) FROM wings") orelse return 0;
        defer db.finalize(stmt);
        if (db.step(stmt) == db.c.SQLITE_ROW) {
            return db.columnInt64(stmt, 0);
        }
        return 0;
    }

    /// Get palace statistics
    pub fn stats(self: *Palace, allocator: Allocator) ![]u8 {
        const wing_n = self.wingCount();
        const drawer_n = self.drawerCount();

        const room_stmt = self.database.prepare("SELECT COUNT(*) FROM rooms") orelse return error.PrepareFailed;
        defer db.finalize(room_stmt);
        var room_n: i64 = 0;
        if (db.step(room_stmt) == db.c.SQLITE_ROW) room_n = db.columnInt64(room_stmt, 0);

        const entity_stmt = self.database.prepare("SELECT COUNT(*) FROM entities") orelse return error.PrepareFailed;
        defer db.finalize(entity_stmt);
        var entity_n: i64 = 0;
        if (db.step(entity_stmt) == db.c.SQLITE_ROW) entity_n = db.columnInt64(entity_stmt, 0);

        return std.fmt.allocPrint(allocator,
            \\╔═══════════════════════════════════╗
            \\║       🏛️  memxt — memory stats     ║
            \\╠═══════════════════════════════════╣
            \\║  Wings:    {d:>8}                 ║
            \\║  Rooms:    {d:>8}                 ║
            \\║  Drawers:  {d:>8}                 ║
            \\║  Entities: {d:>8}                 ║
            \\╚═══════════════════════════════════╝
        , .{
            @as(u64, @intCast(@max(0, wing_n))),
            @as(u64, @intCast(@max(0, room_n))),
            @as(u64, @intCast(@max(0, drawer_n))),
            @as(u64, @intCast(@max(0, entity_n))),
        });
    }
};
