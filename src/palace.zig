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
const quant = @import("quant.zig");

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

        // OR IGNORE on a duplicate leaves last_insert_rowid() at the *previous*
        // insert (often a drawer id) — never trust it when changes()==0.
        if (self.database.changes() == 0) {
            return self.getWingId(name) orelse error.NotFound;
        }
        return self.database.lastInsertRowId();
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

        if (self.database.changes() == 0) {
            return self.getRoomId(wing_id, name) orelse error.NotFound;
        }
        return self.database.lastInsertRowId();
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

    /// SHA-256 hex of content — same hash used for drawer dedup. Callers use
    /// this before embedding so incremental re-mines skip unchanged chunks.
    pub fn contentHashHex(content: []const u8, out: *[64]u8) ![]const u8 {
        var hash_buf: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &hash_buf, .{});
        return std.fmt.bufPrint(out, "{s}", .{std.fmt.bytesToHex(hash_buf, .lower)}) catch return error.HashFailed;
    }

    /// True if a drawer with this content hash already exists (cheap SQL, no embed).
    pub fn hasContentHash(self: *Palace, hash_hex: []const u8) bool {
        const check = self.database.prepare("SELECT 1 FROM drawers WHERE content_hash = ? LIMIT 1") orelse return false;
        defer db.finalize(check);
        db.bindText(check, 1, hash_hex);
        return db.step(check) == db.c.SQLITE_ROW;
    }

    /// Derive drawer kind from source_type and room name for semantic core / wake-up.
    /// Room names win for intentional agent stores (e.g. room=decisions → decision).
    pub fn deriveKind(source_type: []const u8, room_name: []const u8) []const u8 {
        if (std.ascii.eqlIgnoreCase(room_name, "decisions") or
            std.ascii.eqlIgnoreCase(room_name, "decision") or
            std.ascii.eqlIgnoreCase(room_name, "architecture") or
            std.ascii.eqlIgnoreCase(room_name, "adr")) return "decision";
        if (std.ascii.eqlIgnoreCase(room_name, "sessions")) return "episode";
        if (std.ascii.eqlIgnoreCase(room_name, "procedures") or
            std.ascii.eqlIgnoreCase(room_name, "playbooks")) return "procedure";
        if (std.ascii.eqlIgnoreCase(source_type, "decision")) return "decision";
        if (std.ascii.eqlIgnoreCase(source_type, "conversation") or
            std.ascii.eqlIgnoreCase(source_type, "precompact-autosave") or
            std.ascii.eqlIgnoreCase(source_type, "session")) return "episode";
        if (std.ascii.eqlIgnoreCase(source_type, "file")) return "document";
        if (std.ascii.eqlIgnoreCase(source_type, "memory") or std.ascii.eqlIgnoreCase(source_type, "agent")) return "memory";
        return "memory";
    }

    pub fn insertDrawer(
        self: *Palace,
        room_id: i64,
        content: []const u8,
        source_path: []const u8,
        source_type: []const u8,
        chunk_index: i32,
        embedding: []const f32,
    ) !i64 {
        return self.insertDrawerKind(room_id, content, source_path, source_type, chunk_index, embedding, null, null);
    }

    pub fn insertDrawerKind(
        self: *Palace,
        room_id: i64,
        content: []const u8,
        source_path: []const u8,
        source_type: []const u8,
        chunk_index: i32,
        embedding: []const f32,
        kind_override: ?[]const u8,
        supersedes_id: ?i64,
    ) !i64 {
        var hash_hex_buf: [64]u8 = undefined;
        const hex = try contentHashHex(content, &hash_hex_buf);

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

        // Resolve room name for kind derivation (best-effort).
        var room_name: []const u8 = "notes";
        {
            const rs = self.database.prepare("SELECT name FROM rooms WHERE id = ?") orelse null;
            if (rs) |stmt_r| {
                defer db.finalize(stmt_r);
                db.bindInt64(stmt_r, 1, room_id);
                if (db.step(stmt_r) == db.c.SQLITE_ROW) {
                    room_name = db.columnText(stmt_r, 0) orelse "notes";
                }
            }
        }
        const kind = kind_override orelse deriveKind(source_type, room_name);

        // Insert content (+ lifecycle columns when present on schema v3+)
        const stmt = self.database.prepare(
            "INSERT INTO drawers(room_id, content, source_path, source_type, chunk_index, content_hash, kind, tier, supersedes_id) VALUES(?, ?, ?, ?, ?, ?, ?, 'hot', ?)",
        ) orelse return error.PrepareFailed;
        defer db.finalize(stmt);

        db.bindInt64(stmt, 1, room_id);
        db.bindText(stmt, 2, content);
        db.bindText(stmt, 3, source_path);
        db.bindText(stmt, 4, source_type);
        db.bindInt(stmt, 5, chunk_index);
        db.bindText(stmt, 6, hex);
        db.bindText(stmt, 7, kind);
        if (supersedes_id) |sid| {
            db.bindInt64(stmt, 8, sid);
        } else {
            _ = db.c.sqlite3_bind_null(stmt, 8);
        }

        if (db.step(stmt) != db.c.SQLITE_DONE) {
            std.debug.print("drawer insert failed: {s}\n", .{self.database.errmsg()});
            return error.InsertFailed;
        }

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

        // Keep FTS5 in sync for hybrid keyword search.
        {
            const fts = self.database.prepare(
                "INSERT INTO drawers_fts(rowid, content, source_path) VALUES(?, ?, ?)",
            );
            if (fts) |fts_stmt| {
                defer db.finalize(fts_stmt);
                db.bindInt64(fts_stmt, 1, drawer_id);
                db.bindText(fts_stmt, 2, content);
                db.bindText(fts_stmt, 3, source_path);
                _ = db.step(fts_stmt);
            }
        }

        return drawer_id;
    }

    pub const SearchOpts = struct {
        limit: i32 = 20,
        wing: ?[]const u8 = null,
        /// When set, only return drawers whose kind is in this list (comma-separated kinds checked in app).
        kinds: ?[]const []const u8 = null,
        /// Only search drawers still in the hot vector index (default true for hybrid).
        hot_only: bool = true,
    };

    fn kindAllowed(kind: []const u8, kinds: ?[]const []const u8) bool {
        const ks = kinds orelse return true;
        for (ks) |k| {
            if (std.ascii.eqlIgnoreCase(kind, k)) return true;
        }
        return false;
    }

    /// Semantic search across drawers via sqlite-vec (optional wing/kind filter).
    pub fn search(self: *Palace, query_embedding: []const f32, limit: i32, allocator: Allocator) ![]SearchResult {
        return self.searchOpts(query_embedding, .{ .limit = limit }, allocator);
    }

    pub fn searchOpts(self: *Palace, query_embedding: []const f32, opts: SearchOpts, allocator: Allocator) ![]SearchResult {
        // Over-fetch when filtering by wing/kind so post-filter still fills `limit`.
        const k: i32 = if (opts.wing != null or opts.kinds != null) opts.limit * 6 else opts.limit;

        // vec_drawers only holds hot embeddings after dream demotion.
        const sql =
            \\SELECT v.id, v.distance,
            \\       d.content, d.source_path, d.created_at,
            \\       r.name as room_name,
            \\       w.name as wing_name,
            \\       COALESCE(d.kind, 'document'),
            \\       COALESCE(d.tier, 'hot')
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
        db.bindInt(stmt, 2, k);

        var results: std.ArrayListUnmanaged(SearchResult) = .empty;
        errdefer {
            for (results.items) |res| {
                allocator.free(res.content);
                allocator.free(res.source_path);
                allocator.free(res.wing_name);
                allocator.free(res.room_name);
            }
            results.deinit(allocator);
        }

        while (db.step(stmt) == db.c.SQLITE_ROW) {
            const wing_name = db.columnText(stmt, 6) orelse "";
            if (opts.wing) |w| {
                if (!std.mem.eql(u8, wing_name, w)) continue;
            }
            const kind = db.columnText(stmt, 7) orelse "document";
            if (!kindAllowed(kind, opts.kinds)) continue;
            const tier = db.columnText(stmt, 8) orelse "hot";
            if (opts.hot_only and !std.mem.eql(u8, tier, "hot") and !std.mem.eql(u8, tier, "warm")) continue;

            const distance = db.columnDouble(stmt, 1);
            try results.append(allocator, .{
                .drawer_id = db.columnInt64(stmt, 0),
                .content = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
                .source_path = try allocator.dupe(u8, db.columnText(stmt, 3) orelse ""),
                .created_at = db.columnInt64(stmt, 4),
                .room_name = try allocator.dupe(u8, db.columnText(stmt, 5) orelse ""),
                .wing_name = try allocator.dupe(u8, wing_name),
                .distance = distance,
                .score = distance,
            });
            // Touch access stats (best-effort).
            touchAccess(self.database, db.columnInt64(stmt, 0));
            if (results.items.len >= @as(usize, @intCast(opts.limit))) break;
        }

        return results.toOwnedSlice(allocator);
    }

    fn touchAccess(database: *db.Database, drawer_id: i64) void {
        const stmt = database.prepare(
            "UPDATE drawers SET access_count = COALESCE(access_count,0) + 1, last_access = strftime('%s','now') WHERE id = ?",
        ) orelse return;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, drawer_id);
        _ = db.step(stmt);
    }

    /// Demote a drawer to cold: quantize embedding (TurboQuant-style) then drop f32 hot vector.
    /// Content + FTS remain; vec_quant keeps a compact semantic footprint for re-rank.
    pub fn demoteToCold(self: *Palace, drawer_id: i64) !void {
        lockWrites();
        defer unlockWrites();

        // Read f32 embedding before delete.
        var emb_buf: [quant.DIM]f32 = undefined;
        var have_emb = false;
        {
            const rs = self.database.prepare("SELECT embedding FROM vec_drawers WHERE id = ?") orelse null;
            if (rs) |stmt| {
                defer db.finalize(stmt);
                db.bindInt64(stmt, 1, drawer_id);
                if (db.step(stmt) == db.c.SQLITE_ROW) {
                    if (db.columnBlob(stmt, 0)) |blob| {
                        if (blob.len >= quant.DIM * @sizeOf(f32)) {
                            const src: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, blob[0 .. quant.DIM * @sizeOf(f32)]));
                            @memcpy(emb_buf[0..], src[0..quant.DIM]);
                            have_emb = true;
                        }
                    }
                }
            }
        }

        if (have_emb) {
            var qv = quant.quantize(emb_buf[0..], quant.DEFAULT_NBITS, self.allocator) catch null;
            if (qv) |*q| {
                defer q.deinit(self.allocator);
                // Upsert vec_quant
                {
                    const delq = self.database.prepare("DELETE FROM vec_quant WHERE id = ?");
                    if (delq) |dq| {
                        defer db.finalize(dq);
                        db.bindInt64(dq, 1, drawer_id);
                        _ = db.step(dq);
                    }
                }
                const ins = self.database.prepare(
                    "INSERT INTO vec_quant(id, nbits, codes, residual_signs, residual_norm) VALUES(?, ?, ?, ?, ?)",
                );
                if (ins) |iq| {
                    defer db.finalize(iq);
                    db.bindInt64(iq, 1, drawer_id);
                    db.bindInt(iq, 2, q.nbits);
                    db.bindBlob(iq, 3, q.codes);
                    db.bindBlob(iq, 4, q.residual_signs);
                    db.bindDouble(iq, 5, q.residual_norm);
                    _ = db.step(iq);
                }
            }
        }

        {
            const vs = self.database.prepare("DELETE FROM vec_drawers WHERE id = ?") orelse return error.PrepareFailed;
            defer db.finalize(vs);
            db.bindInt64(vs, 1, drawer_id);
            _ = db.step(vs);
        }
        const stmt = self.database.prepare("UPDATE drawers SET tier = 'cold' WHERE id = ?") orelse return error.PrepareFailed;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, drawer_id);
        _ = db.step(stmt);
    }

    /// Promote cold drawer back to hot with a fresh embedding (prefer re-embed over dequant).
    pub fn promoteToHot(self: *Palace, drawer_id: i64, embedding: []const f32) !void {
        lockWrites();
        defer unlockWrites();
        {
            const del = self.database.prepare("DELETE FROM vec_drawers WHERE id = ?") orelse return error.PrepareFailed;
            defer db.finalize(del);
            db.bindInt64(del, 1, drawer_id);
            _ = db.step(del);
        }
        if (embedding.len > 0) {
            const vs = self.database.prepare("INSERT INTO vec_drawers(id, embedding) VALUES(?, ?)") orelse return error.PrepareFailed;
            defer db.finalize(vs);
            db.bindInt64(vs, 1, drawer_id);
            db.bindBlob(vs, 2, std.mem.sliceAsBytes(embedding));
            _ = db.step(vs);
        }
        // Drop quant row — hot f32 is source of truth again.
        {
            const dq = self.database.prepare("DELETE FROM vec_quant WHERE id = ?");
            if (dq) |d| {
                defer db.finalize(d);
                db.bindInt64(d, 1, drawer_id);
                _ = db.step(d);
            }
        }
        const stmt = self.database.prepare("UPDATE drawers SET tier = 'hot' WHERE id = ?") orelse return error.PrepareFailed;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, drawer_id);
        _ = db.step(stmt);
    }

    /// Load quantized vector for a drawer if present.
    pub fn loadQuant(self: *Palace, drawer_id: i64, allocator: Allocator) ?quant.QuantVec {
        const stmt = self.database.prepare(
            "SELECT nbits, codes, residual_signs, residual_norm FROM vec_quant WHERE id = ?",
        ) orelse return null;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, drawer_id);
        if (db.step(stmt) != db.c.SQLITE_ROW) return null;
        const nbits: u8 = @intCast(db.columnInt(stmt, 0));
        const codes_blob = db.columnBlob(stmt, 1) orelse return null;
        const signs_blob = db.columnBlob(stmt, 2);
        const rnorm: f32 = @floatCast(db.columnDouble(stmt, 3));
        const codes = allocator.dupe(u8, codes_blob) catch return null;
        const signs = if (signs_blob) |s| (allocator.dupe(u8, s) catch {
            allocator.free(codes);
            return null;
        }) else (allocator.alloc(u8, 0) catch {
            allocator.free(codes);
            return null;
        });
        return .{
            .nbits = nbits,
            .codes = codes,
            .residual_signs = signs,
            .residual_norm = rnorm,
        };
    }

    pub fn quantCount(self: *Palace) i64 {
        const stmt = self.database.prepare("SELECT COUNT(*) FROM vec_quant") orelse return 0;
        defer db.finalize(stmt);
        if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
        return 0;
    }

    pub fn hotVectorCount(self: *Palace) i64 {
        const stmt = self.database.prepare("SELECT COUNT(*) FROM vec_drawers") orelse return 0;
        defer db.finalize(stmt);
        if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
        return 0;
    }

    /// FTS5 keyword search — exact tokens, identifiers, error codes.
    /// `rank` is BM25 (lower = better in FTS5). Mapped to distance for fusion.
    pub fn searchFts(self: *Palace, query: []const u8, opts: SearchOpts, allocator: Allocator) ![]SearchResult {
        if (query.len == 0) return try allocator.alloc(SearchResult, 0);

        // Build a safe FTS query: quote each token so punctuation/identifiers
        // (0x5C, foo_bar) don't break the FTS parser. OR them for recall.
        var fts_q: std.ArrayListUnmanaged(u8) = .empty;
        defer fts_q.deinit(allocator);

        var it = std.mem.tokenizeAny(u8, query, " \t\n\r,.!?;:()[]{}\"'`");
        var first = true;
        while (it.next()) |tok| {
            if (tok.len < 2) continue;
            // Drop FTS special chars inside tokens.
            var clean_buf: [128]u8 = undefined;
            var clen: usize = 0;
            for (tok) |ch| {
                if (clen >= clean_buf.len) break;
                if (ch == '"' or ch == '*' or ch == '(' or ch == ')' or ch == ':') continue;
                clean_buf[clen] = ch;
                clen += 1;
            }
            if (clen < 2) continue;
            if (!first) try fts_q.appendSlice(allocator, " OR ");
            first = false;
            try fts_q.append(allocator, '"');
            try fts_q.appendSlice(allocator, clean_buf[0..clen]);
            try fts_q.append(allocator, '"');
        }
        if (fts_q.items.len == 0) return try allocator.alloc(SearchResult, 0);

        const sql =
            \\SELECT d.id, bm25(drawers_fts),
            \\       d.content, d.source_path, d.created_at,
            \\       r.name, w.name, COALESCE(d.kind, 'document')
            \\FROM drawers_fts
            \\JOIN drawers d ON d.id = drawers_fts.rowid
            \\JOIN rooms r ON r.id = d.room_id
            \\JOIN wings w ON w.id = r.wing_id
            \\WHERE drawers_fts MATCH ?
            \\ORDER BY bm25(drawers_fts)
            \\LIMIT ?
        ;

        const stmt = self.database.prepare(sql) orelse return try allocator.alloc(SearchResult, 0);
        defer db.finalize(stmt);

        db.bindText(stmt, 1, fts_q.items);
        db.bindInt(stmt, 2, if (opts.wing != null or opts.kinds != null) opts.limit * 6 else opts.limit);

        var results: std.ArrayListUnmanaged(SearchResult) = .empty;
        errdefer {
            for (results.items) |res| {
                allocator.free(res.content);
                allocator.free(res.source_path);
                allocator.free(res.wing_name);
                allocator.free(res.room_name);
            }
            results.deinit(allocator);
        }

        while (db.step(stmt) == db.c.SQLITE_ROW) {
            const wing_name = db.columnText(stmt, 6) orelse "";
            if (opts.wing) |w| {
                if (!std.mem.eql(u8, wing_name, w)) continue;
            }
            const kind = db.columnText(stmt, 7) orelse "document";
            if (!kindAllowed(kind, opts.kinds)) continue;
            // bm25 is negative/lower-better; map to a distance-like positive score.
            const bm = db.columnDouble(stmt, 1);
            const distance = if (bm < 0) -bm else bm;
            try results.append(allocator, .{
                .drawer_id = db.columnInt64(stmt, 0),
                .content = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
                .source_path = try allocator.dupe(u8, db.columnText(stmt, 3) orelse ""),
                .created_at = db.columnInt64(stmt, 4),
                .room_name = try allocator.dupe(u8, db.columnText(stmt, 5) orelse ""),
                .wing_name = try allocator.dupe(u8, wing_name),
                .distance = distance,
                .score = distance,
            });
            touchAccess(self.database, db.columnInt64(stmt, 0));
            if (results.items.len >= @as(usize, @intCast(opts.limit))) break;
        }

        return results.toOwnedSlice(allocator);
    }

    /// Export row for JSONL dump (caller frees string fields).
    pub const ExportRow = struct {
        id: i64,
        wing: []const u8,
        room: []const u8,
        content: []const u8,
        source_path: []const u8,
        source_type: []const u8,
        chunk_index: i32,
        content_hash: []const u8,
        created_at: i64,
    };

    pub const DrawerDetail = struct {
        id: i64,
        wing: []const u8,
        room: []const u8,
        content: []const u8,
        source_path: []const u8,
        kind: []const u8,
        created_at: i64,

        pub fn deinit(self: *DrawerDetail, allocator: Allocator) void {
            allocator.free(self.wing);
            allocator.free(self.room);
            allocator.free(self.content);
            allocator.free(self.source_path);
            allocator.free(self.kind);
        }
    };

    /// Fetch one drawer by id (full content). Used by progressive-disclosure `memory_get`.
    pub fn getDrawer(self: *Palace, id: i64, allocator: Allocator) !?DrawerDetail {
        const stmt = self.database.prepare(
            \\SELECT d.id, w.name, r.name, d.content, COALESCE(d.source_path,''),
            \\       COALESCE(d.kind,''), d.created_at
            \\FROM drawers d
            \\JOIN rooms r ON r.id = d.room_id
            \\JOIN wings w ON w.id = r.wing_id
            \\WHERE d.id = ?
        ) orelse return error.PrepareFailed;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, id);
        if (db.step(stmt) != db.c.SQLITE_ROW) return null;

        const detail: DrawerDetail = .{
            .id = db.columnInt64(stmt, 0),
            .wing = try allocator.dupe(u8, db.columnText(stmt, 1) orelse ""),
            .room = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
            .content = try allocator.dupe(u8, db.columnText(stmt, 3) orelse ""),
            .source_path = try allocator.dupe(u8, db.columnText(stmt, 4) orelse ""),
            .kind = try allocator.dupe(u8, db.columnText(stmt, 5) orelse ""),
            .created_at = db.columnInt64(stmt, 6),
        };
        // Bump access after reading columns (stmt still open is fine for separate UPDATE).
        touchAccess(self.database, id);
        return detail;
    }

    pub fn listExportRows(self: *Palace, wing: ?[]const u8, allocator: Allocator) ![]ExportRow {
        const sql = if (wing != null)
            \\SELECT d.id, w.name, r.name, d.content, d.source_path, d.source_type,
            \\       d.chunk_index, d.content_hash, d.created_at
            \\FROM drawers d
            \\JOIN rooms r ON r.id = d.room_id
            \\JOIN wings w ON w.id = r.wing_id
            \\WHERE w.name = ?
            \\ORDER BY d.id
        else
            \\SELECT d.id, w.name, r.name, d.content, d.source_path, d.source_type,
            \\       d.chunk_index, d.content_hash, d.created_at
            \\FROM drawers d
            \\JOIN rooms r ON r.id = d.room_id
            \\JOIN wings w ON w.id = r.wing_id
            \\ORDER BY d.id
        ;

        const stmt = self.database.prepare(sql) orelse return error.PrepareFailed;
        defer db.finalize(stmt);
        if (wing) |w| db.bindText(stmt, 1, w);

        var rows: std.ArrayListUnmanaged(ExportRow) = .empty;
        errdefer {
            for (rows.items) |row| {
                allocator.free(row.wing);
                allocator.free(row.room);
                allocator.free(row.content);
                allocator.free(row.source_path);
                allocator.free(row.source_type);
                allocator.free(row.content_hash);
            }
            rows.deinit(allocator);
        }

        while (db.step(stmt) == db.c.SQLITE_ROW) {
            try rows.append(allocator, .{
                .id = db.columnInt64(stmt, 0),
                .wing = try allocator.dupe(u8, db.columnText(stmt, 1) orelse ""),
                .room = try allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
                .content = try allocator.dupe(u8, db.columnText(stmt, 3) orelse ""),
                .source_path = try allocator.dupe(u8, db.columnText(stmt, 4) orelse ""),
                .source_type = try allocator.dupe(u8, db.columnText(stmt, 5) orelse "file"),
                .chunk_index = db.columnInt(stmt, 6),
                .content_hash = try allocator.dupe(u8, db.columnText(stmt, 7) orelse ""),
                .created_at = db.columnInt64(stmt, 8),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    /// Delete every drawer (and rooms) in a wing. Returns count of drawers removed.
    pub fn deleteWing(self: *Palace, wing_name: []const u8) !u32 {
        lockWrites();
        defer unlockWrites();

        // Collect drawer ids first so we can clear vec + fts.
        const sel = self.database.prepare(
            \\SELECT d.id FROM drawers d
            \\JOIN rooms r ON r.id = d.room_id
            \\JOIN wings w ON w.id = r.wing_id
            \\WHERE w.name = ?
        ) orelse return error.PrepareFailed;
        defer db.finalize(sel);
        db.bindText(sel, 1, wing_name);

        var ids: [4096]i64 = undefined;
        var n: usize = 0;
        while (db.step(sel) == db.c.SQLITE_ROW and n < ids.len) : (n += 1) {
            ids[n] = db.columnInt64(sel, 0);
        }

        for (ids[0..n]) |did| {
            {
                const vs = self.database.prepare("DELETE FROM vec_drawers WHERE id = ?") orelse continue;
                defer db.finalize(vs);
                db.bindInt64(vs, 1, did);
                _ = db.step(vs);
            }
            {
                const fs = self.database.prepare("DELETE FROM drawers_fts WHERE rowid = ?") orelse continue;
                defer db.finalize(fs);
                db.bindInt64(fs, 1, did);
                _ = db.step(fs);
            }
        }

        // Cascade: rooms → drawers via FK; delete wing last.
        const wing_id = self.getWingId(wing_name) orelse return 0;
        {
            const ds = self.database.prepare(
                \\DELETE FROM drawers WHERE room_id IN (SELECT id FROM rooms WHERE wing_id = ?)
            ) orelse return error.PrepareFailed;
            defer db.finalize(ds);
            db.bindInt64(ds, 1, wing_id);
            _ = db.step(ds);
        }
        {
            const rs = self.database.prepare("DELETE FROM rooms WHERE wing_id = ?") orelse return error.PrepareFailed;
            defer db.finalize(rs);
            db.bindInt64(rs, 1, wing_id);
            _ = db.step(rs);
        }
        {
            const ws = self.database.prepare("DELETE FROM wings WHERE id = ?") orelse return error.PrepareFailed;
            defer db.finalize(ws);
            db.bindInt64(ws, 1, wing_id);
            _ = db.step(ws);
        }
        return @intCast(n);
    }

    /// Delete a single drawer and its vector-table row. The vec row must go too,
    /// otherwise `search` keeps returning a dangling hit whose JOIN to `drawers`
    /// yields nothing. Returns true if a drawer row was actually removed.
    pub fn deleteDrawer(self: *Palace, drawer_id: i64) !bool {
        // Serialize against the miner's insert sequence — both touch drawers +
        // vec_drawers and must not interleave.
        lockWrites();
        defer unlockWrites();

        // Drop the vector row first (no FK cascade reaches the virtual table).
        {
            const vec_stmt = self.database.prepare("DELETE FROM vec_drawers WHERE id = ?") orelse return error.PrepareFailed;
            defer db.finalize(vec_stmt);
            db.bindInt64(vec_stmt, 1, drawer_id);
            _ = db.step(vec_stmt);
        }
        {
            const q_stmt = self.database.prepare("DELETE FROM vec_quant WHERE id = ?");
            if (q_stmt) |qs| {
                defer db.finalize(qs);
                db.bindInt64(qs, 1, drawer_id);
                _ = db.step(qs);
            }
        }
        // FTS5 index (optional — may be missing on pre-v2 palaces mid-migration).
        if (self.database.prepare("DELETE FROM drawers_fts WHERE rowid = ?")) |fts_stmt| {
            defer db.finalize(fts_stmt);
            db.bindInt64(fts_stmt, 1, drawer_id);
            _ = db.step(fts_stmt);
        }

        const stmt = self.database.prepare("DELETE FROM drawers WHERE id = ?") orelse return error.PrepareFailed;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, drawer_id);
        if (db.step(stmt) != db.c.SQLITE_DONE) return error.DeleteFailed;

        return self.database.changes() > 0;
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
