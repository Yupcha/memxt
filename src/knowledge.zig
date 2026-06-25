// ═══════════════════════════════════════════════════════════════════
// memxt/knowledge.zig — Temporal Knowledge Graph
//
// Manages entity-relationship triads (subject -> predicate -> object)
// with temporal valid_from / valid_until tracking.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const Allocator = std.mem.Allocator;

pub const Entity = struct {
    id: i64,
    name: []const u8,
    entity_type: []const u8,
};

pub const Relationship = struct {
    id: i64,
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    confidence: f64,
    valid_from: i64,
    valid_until: ?i64,
    source_drawer_id: ?i64,
};

pub const Graph = struct {
    database: *db.Database,
    allocator: Allocator,

    pub fn init(database: *db.Database, allocator: Allocator) Graph {
        return .{
            .database = database,
            .allocator = allocator,
        };
    }

    /// Get or create an entity node
    pub fn getOrCreateEntity(self: *Graph, name: []const u8, entity_type: []const u8) !i64 {
        const stmt = self.database.prepare(
            "INSERT OR IGNORE INTO entities(name, entity_type) VALUES(?, ?)",
        ) orelse return error.PrepareFailed;
        defer db.finalize(stmt);

        db.bindText(stmt, 1, name);
        db.bindText(stmt, 2, entity_type);

        if (db.step(stmt) != db.c.SQLITE_DONE) return error.InsertFailed;

        const rowid = self.database.lastInsertRowId();
        if (rowid == 0) {
            // Already exists, look it up
            const lookup = self.database.prepare("SELECT id FROM entities WHERE name = ?") orelse return error.PrepareFailed;
            defer db.finalize(lookup);
            db.bindText(lookup, 1, name);
            if (db.step(lookup) == db.c.SQLITE_ROW) {
                // Update last_seen
                const id = db.columnInt64(lookup, 0);
                self.database.exec(std.fmt.allocPrintZ(self.allocator, "UPDATE entities SET last_seen = strftime('%s','now') WHERE id = {d}", .{id}) catch return id);
                return id;
            }
            return error.NotFound;
        }
        return rowid;
    }

    /// Add a relationship edge
    pub fn addEdge(
        self: *Graph,
        subj_name: []const u8,
        pred: []const u8,
        obj_name: []const u8,
        source_drawer_id: ?i64,
    ) !void {
        const subj_id = try self.getOrCreateEntity(subj_name, "concept");
        const obj_id = try self.getOrCreateEntity(obj_name, "concept");

        // Check for existing identical active edge
        const check = self.database.prepare(
            "SELECT id FROM relationships WHERE subject_id = ? AND predicate = ? AND object_id = ? AND valid_until IS NULL",
        ) orelse return error.PrepareFailed;
        defer db.finalize(check);

        db.bindInt64(check, 1, subj_id);
        db.bindText(check, 2, pred);
        db.bindInt64(check, 3, obj_id);

        if (db.step(check) == db.c.SQLITE_ROW) {
            return; // Edge already exists and is active
        }

        // Insert new edge
        const stmt = self.database.prepare(
            "INSERT INTO relationships(subject_id, predicate, object_id, source_drawer_id) VALUES(?, ?, ?, ?)",
        ) orelse return error.PrepareFailed;
        defer db.finalize(stmt);

        db.bindInt64(stmt, 1, subj_id);
        db.bindText(stmt, 2, pred);
        db.bindInt64(stmt, 3, obj_id);
        
        if (source_drawer_id) |did| {
            db.bindInt64(stmt, 4, did);
        } else {
            // We use standard null binding implicitly initially
        }

        if (db.step(stmt) != db.c.SQLITE_DONE) return error.InsertFailed;
    }

    /// Query the temporal graph
    pub fn query(self: *Graph, subject: ?[]const u8, predicate: ?[]const u8) ![]Relationship {
        var base_sql: std.ArrayListUnmanaged(u8) = .empty;
        defer base_sql.deinit(self.allocator);

        try base_sql.appendSlice(self.allocator,
            \\SELECT r.id, s.name, r.predicate, o.name, r.confidence, r.valid_from, r.valid_until, r.source_drawer_id
            \\FROM relationships r
            \\JOIN entities s ON s.id = r.subject_id
            \\JOIN entities o ON o.id = r.object_id
            \\WHERE 1=1
        );

        if (subject != null) try base_sql.appendSlice(self.allocator, " AND s.name = ?");
        if (predicate != null) try base_sql.appendSlice(self.allocator, " AND r.predicate = ?");
        
        try base_sql.appendSlice(self.allocator, " ORDER BY r.valid_from DESC LIMIT 100");

        // We need a null-terminated string for prepare
        try base_sql.append(self.allocator, 0);

        const stmt = self.database.prepare(base_sql.items) orelse return error.PrepareFailed;
        defer db.finalize(stmt);

        var param_idx: c_int = 1;
        if (subject) |s| {
            db.bindText(stmt, param_idx, s);
            param_idx += 1;
        }
        if (predicate) |p| {
            db.bindText(stmt, param_idx, p);
            param_idx += 1;
        }

        var results: std.ArrayListUnmanaged(Relationship) = .empty;
        errdefer {
            for (results.items) |r| {
                self.allocator.free(r.subject);
                self.allocator.free(r.predicate);
                self.allocator.free(r.object);
            }
            results.deinit(self.allocator);
        }

        while (db.step(stmt) == db.c.SQLITE_ROW) {
            var valid_until: ?i64 = null;
            // Need to check if column is null in sqlite
            if (db.c.sqlite3_column_type(stmt, 6) != db.c.SQLITE_NULL) {
                valid_until = db.columnInt64(stmt, 6);
            }

            var drw_id: ?i64 = null;
            if (db.c.sqlite3_column_type(stmt, 7) != db.c.SQLITE_NULL) {
                drw_id = db.columnInt64(stmt, 7);
            }

            try results.append(self.allocator, .{
                .id = db.columnInt64(stmt, 0),
                .subject = try self.allocator.dupe(u8, db.columnText(stmt, 1) orelse ""),
                .predicate = try self.allocator.dupe(u8, db.columnText(stmt, 2) orelse ""),
                .object = try self.allocator.dupe(u8, db.columnText(stmt, 3) orelse ""),
                .confidence = db.columnDouble(stmt, 4),
                .valid_from = db.columnInt64(stmt, 5),
                .valid_until = valid_until,
                .source_drawer_id = drw_id,
            });
        }

        return results.toOwnedSlice(self.allocator);
    }
};
