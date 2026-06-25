// ═══════════════════════════════════════════════════════════════════
// memxt/searcher.zig — Hybrid Search Engine
//
// Combines vector similarity with BM25-style keyword boosting and
// temporal recency weighting.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const palace_mod = @import("palace.zig");

const Allocator = std.mem.Allocator;
const Palace = palace_mod.Palace;
const SearchResult = palace_mod.SearchResult;

const c = @cImport({
    @cInclude("time.h");
});

pub const SearchOptions = struct {
    limit: i32 = 20,
    recency_boost: f64 = 0.1,
    keyword_boost: f64 = 0.2,
    use_llm_reranker: bool = false, // Natively hits Ollama inference
};

/// Perform hybrid search
pub fn searchHybrid(
    palace: *Palace,
    query: []const u8,
    query_embedding: []const f32,
    options: SearchOptions,
    allocator: Allocator,
    io: std.Io,
) ![]SearchResult {
    // 1. Initial retrieval via vector similarity
    var results = try palace.search(query_embedding, options.limit * 2, allocator);
    errdefer {
        for (results) |res| {
            allocator.free(res.content);
            allocator.free(res.source_path);
            allocator.free(res.wing_name);
            allocator.free(res.room_name);
        }
        allocator.free(results);
    }
    
    if (results.len == 0) return results;

    const current_time = c.time(null);

    // Extract basic keywords for naive boosting
    var keywords: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keywords.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, query, " ,.?!;:\t\n");
    while (it.next()) |word| {
        if (word.len > 3) {
            keywords.append(allocator, word) catch continue;
        }
    }

    // 2. Base Re-rank.
    //
    // Convention: LOWER score = better match (we sort ascending below).
    // The vector distance is the dominant signal; recency and exact-keyword
    // matches apply small *discounts* that pull a result up the list. Crucially
    // we do NOT clamp to 0 here — clamping would collapse distinct distances
    // into ties and destroy the ranking the vector index just computed.
    for (results) |*res| {
        var score = res.distance;

        const age_secs = @max(0, current_time - res.created_at);
        const age_ratio = @min(1.0, @as(f64, @floatFromInt(age_secs)) / 7776000.0);
        score -= options.recency_boost * (1.0 - age_ratio); // recent → smaller → better

        var matches: usize = 0;
        for (keywords.items) |kw| {
            if (containsIgnoreCase(res.content, kw)) matches += 1;
        }
        if (keywords.items.len > 0) {
            const kw_ratio = @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(keywords.items.len));
            score -= options.keyword_boost * kw_ratio; // keyword hit → smaller → better
        }

        res.score = score;
    }

    // 3. Optional LLM HTTP Reranking
    if (options.use_llm_reranker) {
        var client = std.http.Client{ .allocator = allocator, .io = io };
        defer client.deinit();
        for (results) |*res| {
            // Very naive LLM prompt structure
            const prompt = std.fmt.allocPrint(allocator, 
                "Does this document align with the query? Document: {s}. Query: {s}. Reply YES or NO.",
                .{ res.content[0..@min(res.content.len, 500)], query }
            ) catch continue;
            defer allocator.free(prompt);

            const payload_str = std.json.Stringify.valueAlloc(allocator, .{
                .model = "llama3",
                .prompt = prompt,
                .stream = false,
            }, .{}) catch continue;
            defer allocator.free(payload_str);

            var res_body = std.Io.Writer.Allocating.init(allocator);
            defer res_body.deinit();

            _ = client.fetch(.{
                .location = .{ .url = "http://localhost:11434/api/generate" },
                .method = .POST,
                .payload = payload_str,
                .response_writer = &res_body.writer,
            }) catch continue;

            const res_str = res_body.written();
            // Give a massive score boost if LLM says "YES"
            if (std.mem.indexOf(u8, res_str, "\"YES\"") != null or std.mem.indexOf(u8, res_str, "\"Yes\"") != null) {
                res.score -= 0.5; // (Lower is better in our logic context)
            }
        }
    }

    // 4. Sort by new score
    std.mem.sort(SearchResult, results, {}, struct {
        fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
            return a.score < b.score; // Lower is better
        }
    }.lessThan);

    // 4. Truncate to requested limit
    if (results.len > options.limit) {
        // Free the items we're truncating
        for (results[@intCast(options.limit)..]) |res| {
            allocator.free(res.content);
            allocator.free(res.source_path);
            allocator.free(res.wing_name);
            allocator.free(res.room_name);
        }
        return allocator.realloc(results, @intCast(options.limit)) catch results[0..@intCast(options.limit)];
    }

    return results;
}

/// Case-insensitive substring search (ASCII). Used for the small keyword
/// discount on top of vector ranking.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
