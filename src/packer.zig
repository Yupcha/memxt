// ═══════════════════════════════════════════════════════════════════
// memxt/packer.zig — Token-budget-aware context packing
//
// Turns ranked candidate items (facts, profile entries, drawer bodies)
// into ONE markdown brief that fits a token budget. Highest value per
// token first: dense one-liners (facts/profile) before drawer content,
// the final item trimmed at a line/sentence boundary, near-identical
// lines deduped, and drawer ids always kept so the agent can
// memory_get for more.
//
// No external tokenizer — a cheap chars/4 heuristic (with a small
// surcharge for symbol-dense/code text) is plenty for budgeting.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Cheap token estimate: ~4 chars/token for prose; punctuation/symbol-dense
/// text (code) and hard newlines tokenize worse, so charge a little extra.
pub fn estimateTokens(text: []const u8) usize {
    if (text.len == 0) return 0;
    var symbols: usize = 0;
    var newlines: usize = 0;
    for (text) |ch| {
        switch (ch) {
            '\n' => newlines += 1,
            'a'...'z', 'A'...'Z', '0'...'9', ' ' => {},
            else => symbols += 1,
        }
    }
    return text.len / 4 + symbols / 4 + newlines / 2 + 1;
}

pub const ItemKind = enum {
    /// Structured fact triple — dense, packed first.
    fact,
    /// Versioned profile entry — dense, packed first.
    profile,
    /// Short drawer excerpt — packed after dense items.
    snippet,
    /// Full drawer body — packed after dense items.
    body,

    fn isDense(self: ItemKind) bool {
        return self == .fact or self == .profile;
    }
};

/// One ranked candidate for the brief. Callers pass items already sorted
/// best-first (the packer preserves relative order within each tier).
pub const Item = struct {
    kind: ItemKind,
    text: []const u8,
    drawer_id: ?i64 = null,
    /// Provenance shown in the drawer header, e.g. "[wing/room] path".
    label: []const u8 = "",
};

pub const Packed = struct {
    text: []u8,
    used_tokens: usize,
    included: usize,
    total: usize,

    pub fn deinit(self: *Packed, allocator: Allocator) void {
        allocator.free(self.text);
    }
};

/// Pack ranked items into a single markdown brief that estimates within
/// `budget_tokens`. Dense items (facts, profile) go first; drawer content
/// follows in ranked order; the first drawer item that doesn't fit whole is
/// trimmed at a line/sentence boundary and packing stops there. Skipped
/// drawer ids are listed in a trailing "more" line when they fit.
pub fn pack(items: []const Item, budget_tokens: usize, allocator: Allocator) !Packed {
    var b = Builder{ .budget = budget_tokens, .allocator = allocator };
    defer b.deinit();

    var included: usize = 0;
    var skipped_ids: std.ArrayListUnmanaged(i64) = .empty;
    defer skipped_ids.deinit(allocator);

    // Tier 1: dense one-liners — best value per token.
    for (items) |item| {
        if (!item.kind.isDense()) continue;
        if (try appendDense(&b, item)) {
            included += 1;
        } else if (item.drawer_id) |id| {
            try skipped_ids.append(allocator, id);
        }
    }

    // Tier 2: drawer snippets/bodies, in given (ranked) order. Once one is
    // trimmed or rejected the budget is spent — collect the rest as ids.
    var room_left = true;
    for (items) |item| {
        if (item.kind.isDense()) continue;
        if (room_left) {
            switch (try appendDrawer(&b, item)) {
                .full => {
                    included += 1;
                    continue;
                },
                .trimmed => {
                    included += 1;
                    room_left = false;
                    continue;
                },
                .none => room_left = false,
            }
        }
        if (item.drawer_id) |id| try skipped_ids.append(allocator, id);
    }

    if (skipped_ids.items.len > 0) try appendMoreFooter(&b, skipped_ids.items);

    const text = try b.out.toOwnedSlice(allocator);
    return .{
        .text = text,
        .used_tokens = estimateTokens(text),
        .included = included,
        .total = items.len,
    };
}

/// Re-fit an already-assembled brief (e.g. the wake-up L0/L1/L2 text) to a
/// token budget. Lines keep their order — earlier sections win, so priority
/// is whatever order the caller assembled (L0 > L1 > L2 for wake-up).
/// Duplicate lines (normalized whitespace) are dropped and the cut lands on
/// a line (or sentence) boundary; a section header left with no content is
/// removed.
pub fn fitToBudget(full: []const u8, budget_tokens: usize, allocator: Allocator) ![]u8 {
    var b = Builder{ .budget = budget_tokens, .allocator = allocator };
    defer b.deinit();

    var truncated = false;
    var it = std.mem.splitScalar(u8, full, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        // Dedupe content lines only — headers and blanks structure the brief.
        if (line.len > 0 and line[0] != '#') {
            if (try b.isDuplicate(line)) continue;
        }
        const piece = try std.fmt.allocPrint(allocator, "{s}\n", .{line});
        defer allocator.free(piece);
        if (!try b.tryAppend(piece)) {
            if (line.len > 0) _ = try trySentenceTrim(&b, line);
            truncated = true;
            break;
        }
    }

    dropDanglingHeader(&b);
    if (truncated) _ = try b.tryAppend("(trimmed to token budget)\n");

    return b.out.toOwnedSlice(allocator);
}

// ── Internals ──

/// Accumulates the brief while enforcing the budget and line-level dedupe.
const Builder = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    budget: usize,
    allocator: Allocator,

    fn deinit(self: *Builder) void {
        var it = self.seen.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.seen.deinit(self.allocator);
        self.out.deinit(self.allocator);
    }

    /// Append `s` only if the whole brief still estimates within budget.
    /// Rolls back and returns false otherwise.
    fn tryAppend(self: *Builder, s: []const u8) !bool {
        const prev = self.out.items.len;
        try self.out.appendSlice(self.allocator, s);
        if (estimateTokens(self.out.items) > self.budget) {
            self.out.shrinkRetainingCapacity(prev);
            return false;
        }
        return true;
    }

    /// True when a normalized-whitespace duplicate of `line` was already
    /// packed. Registers the line otherwise.
    fn isDuplicate(self: *Builder, line: []const u8) !bool {
        const norm = try normalizeLine(line, self.allocator);
        if (norm.len == 0) {
            self.allocator.free(norm);
            return false;
        }
        if (self.seen.contains(norm)) {
            self.allocator.free(norm);
            return true;
        }
        try self.seen.put(self.allocator, norm, {});
        return false;
    }
};

/// Trim + collapse whitespace runs to single spaces (dedupe key).
fn normalizeLine(line: []const u8, allocator: Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var pending_space = false;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
            pending_space = buf.items.len != 0;
        } else {
            if (pending_space) try buf.append(allocator, ' ');
            pending_space = false;
            try buf.append(allocator, ch);
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Render a fact/profile entry as one bullet line. Returns true if packed.
fn appendDense(b: *Builder, item: Item) !bool {
    // Flatten and normalize to one line — dense items are one-liners by
    // construction, and normalized rendering makes the dedupe airtight.
    const content = try normalizeLine(item.text, b.allocator);
    defer b.allocator.free(content);
    if (content.len == 0) return false;
    // Dedupe on the content itself so the same fact under two ids collapses.
    if (try b.isDuplicate(content)) return false;

    const line = if (item.drawer_id) |id|
        try std.fmt.allocPrint(b.allocator, "- {s} (#{d})\n", .{ content, id })
    else
        try std.fmt.allocPrint(b.allocator, "- {s}\n", .{content});
    defer b.allocator.free(line);
    return b.tryAppend(line);
}

const DrawerAdd = enum { full, trimmed, none };

/// Render a drawer snippet/body under a "### #id [label]" header, line by
/// line. The first line that doesn't fit is sentence-trimmed and packing of
/// this item stops. A header left with no content is rolled back.
fn appendDrawer(b: *Builder, item: Item) !DrawerAdd {
    const sep: []const u8 = if (b.out.items.len == 0) "" else "\n";
    const header = if (item.drawer_id) |id|
        try std.fmt.allocPrint(b.allocator, "{s}### #{d} {s}\n", .{ sep, id, item.label })
    else
        try std.fmt.allocPrint(b.allocator, "{s}### {s}\n", .{ sep, item.label });
    defer b.allocator.free(header);

    const mark = b.out.items.len;
    if (!try b.tryAppend(header)) return .none;

    var lines_added: usize = 0;
    var trimmed = false;
    var it = std.mem.splitScalar(u8, item.text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (try b.isDuplicate(line)) continue;
        const piece = try std.fmt.allocPrint(b.allocator, "{s}\n", .{line});
        defer b.allocator.free(piece);
        if (try b.tryAppend(piece)) {
            lines_added += 1;
            continue;
        }
        if (try trySentenceTrim(b, line)) lines_added += 1;
        trimmed = true;
        break;
    }

    if (lines_added == 0) {
        // Header without any content is noise — roll it back entirely.
        b.out.shrinkRetainingCapacity(mark);
        return .none;
    }
    return if (trimmed) .trimmed else .full;
}

/// Try successively shorter sentence-bounded prefixes of `line` until one
/// fits the budget. Returns true if a prefix was packed.
fn trySentenceTrim(b: *Builder, line: []const u8) !bool {
    var end: usize = line.len;
    while (findLastSentenceEnd(line[0..end])) |cut| {
        if (cut == 0) break;
        const piece = try std.fmt.allocPrint(b.allocator, "{s}\n", .{line[0..cut]});
        defer b.allocator.free(piece);
        if (try b.tryAppend(piece)) return true;
        end = cut - 1;
    }
    return false;
}

/// Index just past the last '.', '!' or '?' that ends a sentence in `s`.
fn findLastSentenceEnd(s: []const u8) ?usize {
    var i = s.len;
    while (i > 0) : (i -= 1) {
        const ch = s[i - 1];
        if (ch == '.' or ch == '!' or ch == '?') {
            if (i == s.len or s[i] == ' ') return i;
        }
    }
    return null;
}

/// Point the agent at what didn't fit: "(more: memory_get #a #b …)".
/// Rolled back entirely if no id fits.
fn appendMoreFooter(b: *Builder, ids: []const i64) !void {
    const mark = b.out.items.len;
    if (!try b.tryAppend("\n(more: memory_get ")) return;
    var n: usize = 0;
    for (ids) |id| {
        if (id < 0) continue; // synthetic fact ids aren't fetchable
        const piece = if (n == 0)
            try std.fmt.allocPrint(b.allocator, "#{d}", .{id})
        else
            try std.fmt.allocPrint(b.allocator, " #{d}", .{id});
        defer b.allocator.free(piece);
        if (!try b.tryAppend(piece)) break;
        n += 1;
    }
    if (n == 0 or !try b.tryAppend(")\n")) {
        b.out.shrinkRetainingCapacity(mark);
    }
}

/// Drop trailing section headers ("#…") that ended up with no content
/// beneath them after a budget cut.
fn dropDanglingHeader(b: *Builder) void {
    while (true) {
        var end = b.out.items.len;
        while (end > 0 and (b.out.items[end - 1] == '\n' or b.out.items[end - 1] == ' ')) end -= 1;
        if (end == 0) {
            b.out.shrinkRetainingCapacity(0);
            return;
        }
        const start = if (std.mem.lastIndexOfScalar(u8, b.out.items[0..end], '\n')) |nl| nl + 1 else 0;
        if (b.out.items[start] != '#') {
            // Every packed line ends in '\n', so end < len here — capacity holds.
            b.out.shrinkRetainingCapacity(end);
            b.out.appendAssumeCapacity('\n');
            return;
        }
        b.out.shrinkRetainingCapacity(start);
    }
}

// ── Tests ──

test "estimateTokens sanity" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(""));

    const prose = "The quick brown fox jumps over the lazy dog near the bank";
    const t = estimateTokens(prose);
    // Roughly chars/4: within a sane band, and monotonic in length.
    try std.testing.expect(t >= prose.len / 6);
    try std.testing.expect(t <= prose.len / 2);
    try std.testing.expect(estimateTokens(prose ++ " " ++ prose) > t);

    // Symbol-dense code costs more than prose of the same length.
    const code = "fn f(x:u8)u8{return x*2;}//ok!!!"; // 32 chars
    const flat = "the cat sat on the warm mat now "; // 32 chars
    try std.testing.expect(estimateTokens(code) > estimateTokens(flat));
}

test "pack puts dense facts before drawer bodies" {
    const items = [_]Item{
        .{ .kind = .body, .text = "long body content goes here", .drawer_id = 7, .label = "[w/r] src.zig" },
        .{ .kind = .fact, .text = "project uses Zig 0.16", .drawer_id = 3 },
    };
    var pk = try pack(&items, 200, std.testing.allocator);
    defer pk.deinit(std.testing.allocator);

    const fact_pos = std.mem.indexOf(u8, pk.text, "Zig 0.16").?;
    const body_pos = std.mem.indexOf(u8, pk.text, "long body content").?;
    try std.testing.expect(fact_pos < body_pos);
    // Drawer ids stay visible for memory_get follow-up.
    try std.testing.expect(std.mem.indexOf(u8, pk.text, "#7") != null);
    try std.testing.expect(std.mem.indexOf(u8, pk.text, "#3") != null);
    try std.testing.expectEqual(@as(usize, 2), pk.included);
}

test "pack respects the token budget" {
    const items = [_]Item{
        .{ .kind = .fact, .text = "the palace database lives in ~/.memxt/palace.db by default" },
        .{ .kind = .body, .text = "First drawer body line one is fairly long and wordy.\nSecond line adds even more detail about the system.\nThird line keeps going with implementation notes.", .drawer_id = 11, .label = "[w/notes] a.md" },
        .{ .kind = .body, .text = "Another drawer with its own long-winded body that certainly will not fit inside a small budget at all.", .drawer_id = 12, .label = "[w/notes] b.md" },
        .{ .kind = .snippet, .text = "yet another snippet of moderately useful context", .drawer_id = 13, .label = "[w/notes] c.md" },
    };
    const budget: usize = 40;
    var pk = try pack(&items, budget, std.testing.allocator);
    defer pk.deinit(std.testing.allocator);

    try std.testing.expect(estimateTokens(pk.text) <= budget);
    try std.testing.expectEqual(pk.used_tokens, estimateTokens(pk.text));
    try std.testing.expect(pk.included < pk.total);
}

test "final item trims at a line boundary" {
    const body = "alpha alpha alpha alpha\nbeta beta beta beta\ngamma gamma gamma gamma\ndelta delta delta delta";
    const items = [_]Item{
        .{ .kind = .body, .text = body, .drawer_id = 1, .label = "x" },
    };
    var pk = try pack(&items, 12, std.testing.allocator);
    defer pk.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, pk.text, "alpha alpha alpha alpha\n") != null);
    // Every packed content line is one of the original lines, whole — never
    // a mid-word cut (the body has no sentence punctuation to trim to).
    var it = std.mem.splitScalar(u8, pk.text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '(') continue;
        try std.testing.expect(std.mem.eql(u8, line, "alpha alpha alpha alpha") or
            std.mem.eql(u8, line, "beta beta beta beta") or
            std.mem.eql(u8, line, "gamma gamma gamma gamma"));
    }
    try std.testing.expect(estimateTokens(pk.text) <= 12);
}

test "near-identical lines are deduped" {
    const items = [_]Item{
        .{ .kind = .fact, .text = "uses  SQLite   FTS5" },
        .{ .kind = .fact, .text = "uses SQLite FTS5" },
        .{ .kind = .body, .text = "uses SQLite FTS5\nplus vector search via sqlite-vec", .drawer_id = 5, .label = "y" },
    };
    var pk = try pack(&items, 200, std.testing.allocator);
    defer pk.deinit(std.testing.allocator);

    // The fact appears once; the body's duplicate first line is dropped too.
    const count = std.mem.count(u8, pk.text, "SQLite FTS5");
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, pk.text, "sqlite-vec") != null);
}

test "fitToBudget keeps early sections and cuts on a line boundary" {
    const full =
        "## L0 — IDENTITY\nidentity line\n\n## L1 — PROJECT PROFILE\n" ++
        "profile line one with some words\nprofile line two with some words\n\n" ++
        "## L2 — RECENT WORK\nrecent item aaa\nrecent item bbb\nrecent item ccc\n";
    const fitted = try fitToBudget(full, 14, std.testing.allocator);
    defer std.testing.allocator.free(fitted);

    try std.testing.expect(std.mem.indexOf(u8, fitted, "## L0") != null);
    try std.testing.expect(std.mem.indexOf(u8, fitted, "identity line") != null);
    try std.testing.expect(std.mem.indexOf(u8, fitted, "recent item ccc") == null);
    try std.testing.expect(estimateTokens(fitted) <= 14);

    // A roomy budget keeps everything.
    const roomy = try fitToBudget(full, 10_000, std.testing.allocator);
    defer std.testing.allocator.free(roomy);
    try std.testing.expect(std.mem.indexOf(u8, roomy, "recent item ccc") != null);
}
