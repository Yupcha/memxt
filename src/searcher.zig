// ═══════════════════════════════════════════════════════════════════
// memxt/searcher.zig — Multi-mode hybrid search
//
// Modes: hybrid | memories | documents | facts | episodes
// Score convention: LOWER = better.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const palace_mod = @import("palace.zig");
const facts_mod = @import("facts.zig");
const quant = @import("quant.zig");
const telemetry = @import("telemetry.zig");

const Allocator = std.mem.Allocator;
const Palace = palace_mod.Palace;
const SearchResult = palace_mod.SearchResult;

const c = @cImport({
    @cInclude("time.h");
});

pub const SearchMode = enum {
    hybrid,
    memories,
    documents,
    facts,
    episodes,

    pub fn parse(s: []const u8) ?SearchMode {
        if (std.mem.eql(u8, s, "hybrid") or std.mem.eql(u8, s, "auto")) return .hybrid;
        if (std.mem.eql(u8, s, "memories") or std.mem.eql(u8, s, "memory")) return .memories;
        if (std.mem.eql(u8, s, "documents") or std.mem.eql(u8, s, "docs") or std.mem.eql(u8, s, "document")) return .documents;
        if (std.mem.eql(u8, s, "facts") or std.mem.eql(u8, s, "fact")) return .facts;
        if (std.mem.eql(u8, s, "episodes") or std.mem.eql(u8, s, "episode") or std.mem.eql(u8, s, "sessions")) return .episodes;
        return null;
    }

    pub fn name(self: SearchMode) []const u8 {
        return switch (self) {
            .hybrid => "hybrid",
            .memories => "memories",
            .documents => "documents",
            .facts => "facts",
            .episodes => "episodes",
        };
    }
};

pub const SearchOptions = struct {
    limit: i32 = 20,
    wing: ?[]const u8 = null,
    mode: SearchMode = .hybrid,
    as_of: ?i64 = null,
    recency_boost: f64 = 0.1,
    fts_boost: f64 = 0.35,
    keyword_boost: f64 = 0.15,
    use_llm_reranker: bool = false,
};

const memory_kinds = [_][]const u8{ "memory", "decision", "episode", "procedure" };
const document_kinds = [_][]const u8{"document"};
const episode_kinds = [_][]const u8{"episode"};

const MergeHit = struct {
    drawer_id: i64,
    content: []const u8,
    source_path: []const u8,
    wing_name: []const u8,
    room_name: []const u8,
    created_at: i64,
    distance: f64,
    rrf: f64,
    owned: bool,
};

pub fn search(
    palace: *Palace,
    query: []const u8,
    query_embedding: []const f32,
    options: SearchOptions,
    allocator: Allocator,
    io: std.Io,
) ![]SearchResult {
    if (options.mode == .facts) return searchFacts(palace, query, options, allocator);
    return searchHybrid(palace, query, query_embedding, options, allocator, io);
}

/// Backward-compatible alias.
pub fn searchHybrid(
    palace: *Palace,
    query: []const u8,
    query_embedding: []const f32,
    options: SearchOptions,
    allocator: Allocator,
    io: std.Io,
) ![]SearchResult {
    _ = io;

    const kinds: ?[]const []const u8 = switch (options.mode) {
        .memories => memory_kinds[0..],
        .documents => document_kinds[0..],
        .episodes => episode_kinds[0..],
        .hybrid, .facts => null,
    };

    const candidate_limit = options.limit * 2;
    const palace_opts = palace_mod.Palace.SearchOpts{
        .limit = candidate_limit,
        .wing = options.wing,
        .kinds = kinds,
        .hot_only = true,
    };

    var vec_results: []SearchResult = &[_]SearchResult{};
    var free_vec = false;
    if (query_embedding.len > 0) {
        vec_results = try palace.searchOpts(query_embedding, palace_opts, allocator);
        free_vec = true;
    }
    defer if (free_vec) freeResults(allocator, vec_results);

    var fts_opts = palace_opts;
    fts_opts.hot_only = false;
    const fts_results = palace.searchFts(query, fts_opts, allocator) catch
        try allocator.alloc(SearchResult, 0);
    defer freeResults(allocator, fts_results);

    const RRF_K: f64 = 60.0;

    var merged: std.ArrayListUnmanaged(MergeHit) = .empty;
    defer {
        for (merged.items) |h| {
            if (h.owned) {
                allocator.free(h.content);
                allocator.free(h.source_path);
                allocator.free(h.wing_name);
                allocator.free(h.room_name);
            }
        }
        merged.deinit(allocator);
    }

    var id_to_idx: std.AutoHashMapUnmanaged(i64, usize) = .empty;
    defer id_to_idx.deinit(allocator);

    for (vec_results, 0..) |res, rank| {
        const rrf = 1.0 / (RRF_K + @as(f64, @floatFromInt(rank + 1)));
        try merged.append(allocator, .{
            .drawer_id = res.drawer_id,
            .content = res.content,
            .source_path = res.source_path,
            .wing_name = res.wing_name,
            .room_name = res.room_name,
            .created_at = res.created_at,
            .distance = res.distance,
            .rrf = rrf,
            .owned = false,
        });
        try id_to_idx.put(allocator, res.drawer_id, merged.items.len - 1);
    }

    for (fts_results, 0..) |res, rank| {
        const rrf = options.fts_boost * (1.0 / (RRF_K + @as(f64, @floatFromInt(rank + 1))));
        if (id_to_idx.get(res.drawer_id)) |idx| {
            merged.items[idx].rrf += rrf;
            if (res.distance < merged.items[idx].distance) merged.items[idx].distance = res.distance;
        } else {
            try merged.append(allocator, .{
                .drawer_id = res.drawer_id,
                .content = try allocator.dupe(u8, res.content),
                .source_path = try allocator.dupe(u8, res.source_path),
                .wing_name = try allocator.dupe(u8, res.wing_name),
                .room_name = try allocator.dupe(u8, res.room_name),
                .created_at = res.created_at,
                .distance = res.distance,
                .rrf = rrf,
                .owned = true,
            });
            try id_to_idx.put(allocator, res.drawer_id, merged.items.len - 1);
        }
    }

    if (options.mode == .hybrid) {
        try appendMatchingFacts(palace, query, options, &merged, allocator);
    }

    // Re-rank cold/quantized hits with TurboQuant dequant (semantic recovery without f32 hot index).
    if (query_embedding.len == quant.DIM) {
        reRankWithQuant(palace, query_embedding, &merged, allocator);
    }

    if (merged.items.len == 0) return try allocator.alloc(SearchResult, 0);

    // Usage-learned relevance: identity when telemetry is empty/absent.
    var utility = telemetry.UtilityLookup.init(palace.database);
    defer utility.deinit();

    const current_time = c.time(null);
    var keywords: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keywords.deinit(allocator);
    var kit = std.mem.tokenizeAny(u8, query, " ,.?!;:\t\n");
    while (kit.next()) |word| {
        if (word.len > 2) keywords.append(allocator, word) catch continue;
    }

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

    for (merged.items) |h| {
        var score = h.distance - h.rrf;
        const age_secs = @max(0, current_time - h.created_at);
        const age_ratio = @min(1.0, @as(f64, @floatFromInt(age_secs)) / 7776000.0);
        score -= options.recency_boost * (1.0 - age_ratio);
        var matches: usize = 0;
        for (keywords.items) |kw| {
            if (containsIgnoreCase(h.content, kw)) matches += 1;
        }
        if (keywords.items.len > 0) {
            score -= options.keyword_boost * (@as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(keywords.items.len)));
        }
        score = utility.boost(h.drawer_id, score);
        try results.append(allocator, .{
            .drawer_id = h.drawer_id,
            .content = try allocator.dupe(u8, h.content),
            .source_path = try allocator.dupe(u8, h.source_path),
            .wing_name = try allocator.dupe(u8, h.wing_name),
            .room_name = try allocator.dupe(u8, h.room_name),
            .created_at = h.created_at,
            .distance = h.distance,
            .score = score,
        });
    }

    std.mem.sort(SearchResult, results.items, {}, struct {
        fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
            return a.score < b.score;
        }
    }.lessThan);

    if (results.items.len > @as(usize, @intCast(options.limit))) {
        for (results.items[@intCast(options.limit)..]) |res| {
            allocator.free(res.content);
            allocator.free(res.source_path);
            allocator.free(res.wing_name);
            allocator.free(res.room_name);
        }
        results.shrinkRetainingCapacity(@intCast(options.limit));
    }
    return results.toOwnedSlice(allocator);
}

fn reRankWithQuant(
    palace: *Palace,
    query_embedding: []const f32,
    merged: *std.ArrayListUnmanaged(MergeHit),
    allocator: Allocator,
) void {
    for (merged.items) |*h| {
        if (h.drawer_id < 0) continue; // synthetic facts
        var qv = palace.loadQuant(h.drawer_id, allocator) orelse continue;
        defer qv.deinit(allocator);
        // Cosine ≈ 1 - dist/2 for unit vectors; map to distance-like score (lower better).
        const cos = quant.cosine(query_embedding, qv);
        const dist = @max(0.0, 1.0 - cos);
        // Prefer quant geometry over weak FTS-only distance when available.
        if (dist < h.distance or h.distance > 0.5) {
            h.distance = dist;
            h.rrf += 0.25; // boost recovered semantic hit
        }
    }
}

fn appendMatchingFacts(
    palace: *Palace,
    query: []const u8,
    options: SearchOptions,
    merged: *std.ArrayListUnmanaged(MergeHit),
    allocator: Allocator,
) !void {
    const wing_name = options.wing orelse return;
    const wing_id = palace.getWingId(wing_name) orelse return;
    const fl = if (options.as_of) |ts|
        facts_mod.listAsOf(palace.database, wing_id, ts, 20, allocator) catch return
    else
        facts_mod.listActive(palace.database, wing_id, 20, allocator) catch return;
    defer facts_mod.freeFacts(fl, allocator);

    var syn_id: i64 = -1;
    for (fl) |f| {
        var hit = containsIgnoreCase(f.object, query) or containsIgnoreCase(f.subject, query);
        if (!hit) {
            var it = std.mem.tokenizeAny(u8, query, " \t");
            while (it.next()) |tok| {
                if (tok.len < 3) continue;
                if (containsIgnoreCase(f.object, tok) or containsIgnoreCase(f.subject, tok)) {
                    hit = true;
                    break;
                }
            }
        }
        if (!hit) continue;
        // Prefer real source drawer so progressive disclosure (memory_get) works.
        // Only use synthetic negative ids when the fact has no drawer provenance.
        const did: i64 = if (f.source_drawer_id) |sid| sid else blk: {
            const id = syn_id;
            syn_id -= 1;
            break :blk id;
        };
        const text = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ f.subject, f.predicate, f.object });
        try merged.append(allocator, .{
            .drawer_id = did,
            .content = text,
            .source_path = try allocator.dupe(u8, "fact"),
            .wing_name = try allocator.dupe(u8, wing_name),
            .room_name = try allocator.dupe(u8, "facts"),
            .created_at = f.valid_from,
            .distance = 0.2,
            .rrf = 0.5,
            .owned = true,
        });
    }
}

fn searchFacts(palace: *Palace, query: []const u8, options: SearchOptions, allocator: Allocator) ![]SearchResult {
    const wing_name = options.wing orelse return try allocator.alloc(SearchResult, 0);
    const wing_id = palace.getWingId(wing_name) orelse return try allocator.alloc(SearchResult, 0);

    const fl = if (options.as_of) |ts|
        try facts_mod.listAsOf(palace.database, wing_id, ts, options.limit * 2, allocator)
    else
        try facts_mod.listActive(palace.database, wing_id, options.limit * 2, allocator);
    defer facts_mod.freeFacts(fl, allocator);

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

    for (fl) |f| {
        const hay = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ f.subject, f.predicate, f.object });
        var score: f64 = 1.0;
        if (query.len > 0 and containsIgnoreCase(hay, query)) score = 0.1;
        var it = std.mem.tokenizeAny(u8, query, " \t");
        while (it.next()) |tok| {
            if (tok.len > 2 and containsIgnoreCase(hay, tok)) score -= 0.15;
        }
        try results.append(allocator, .{
            .drawer_id = f.id,
            .content = hay,
            .source_path = try allocator.dupe(u8, "fact"),
            .wing_name = try allocator.dupe(u8, wing_name),
            .room_name = try allocator.dupe(u8, "facts"),
            .created_at = f.valid_from,
            .distance = score,
            .score = score,
        });
    }

    std.mem.sort(SearchResult, results.items, {}, struct {
        fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
            return a.score < b.score;
        }
    }.lessThan);

    if (results.items.len > @as(usize, @intCast(options.limit))) {
        for (results.items[@intCast(options.limit)..]) |res| {
            allocator.free(res.content);
            allocator.free(res.source_path);
            allocator.free(res.wing_name);
            allocator.free(res.room_name);
        }
        results.shrinkRetainingCapacity(@intCast(options.limit));
    }
    return results.toOwnedSlice(allocator);
}

fn freeResults(allocator: Allocator, results: []SearchResult) void {
    for (results) |res| {
        allocator.free(res.content);
        allocator.free(res.source_path);
        allocator.free(res.wing_name);
        allocator.free(res.room_name);
    }
    allocator.free(results);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
