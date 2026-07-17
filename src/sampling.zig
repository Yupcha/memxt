// ═══════════════════════════════════════════════════════════════════
// memxt/sampling.zig — MCP sampling (server → client createMessage)
//
// MCP lets a server send `sampling/createMessage` requests back to the
// CLIENT, so the client's own model does the thinking — zero extra API
// keys, nothing leaves the machine beyond the client that already holds
// the conversation. memxt uses it (opt-in, MEMXT_SAMPLING=1) to ask the
// client model for durable facts at memory_store time.
//
// The hard part in a synchronous stdio loop is correlation: after we
// write our request onto stdout we must keep reading stdin until the
// response with OUR id arrives, while any interleaved client→server
// messages are queued (not dropped) for the main loop to answer later.
// `Correlator` owns exactly that: line framing, id matching, queuing,
// and a poll(2)-based timeout so a silent client can never wedge the
// server — on timeout the caller falls back to the heuristic extractor.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const facts = @import("facts.zig");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("time.h");
    @cInclude("stdlib.h");
});

/// How long we wait for the client model before falling back to heuristics.
pub const DEFAULT_TIMEOUT_MS: i32 = 30_000;

/// Cap on how much of the stored body is shipped to the client model.
pub const MAX_CONTENT_CHARS: usize = 4000;

// ── Byte stream abstraction (injectable for tests) ──

/// A minimal duplex byte stream: real serving wraps stdin/stdout
/// (`StdioStream`); tests inject scripted buffers.
pub const Stream = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, buf: []u8, timeout_ms: i32) ReadError!usize,
    writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) WriteError!void,

    pub const ReadError = error{ Timeout, ReadFailed };
    pub const WriteError = error{WriteFailed};

    /// Read up to buf.len bytes. `timeout_ms < 0` blocks indefinitely.
    /// Returns 0 on end-of-stream; error.Timeout when nothing arrived in time.
    pub fn read(self: Stream, buf: []u8, timeout_ms: i32) ReadError!usize {
        return self.readFn(self.ctx, buf, timeout_ms);
    }

    pub fn write(self: Stream, bytes: []const u8) WriteError!void {
        return self.writeFn(self.ctx, bytes);
    }
};

/// Production stream over fd 0/1. Timeouts use poll(2) on stdin so a
/// blocking wait for a sampling response can still give up gracefully.
pub const StdioStream = struct {
    io: std.Io,

    pub fn stream(self: *StdioStream) Stream {
        return .{ .ctx = self, .readFn = readFn, .writeFn = writeFn };
    }

    fn readFn(ctx: *anyopaque, buf: []u8, timeout_ms: i32) Stream.ReadError!usize {
        const self: *StdioStream = @ptrCast(@alignCast(ctx));
        if (timeout_ms >= 0) {
            var fds = [1]c.struct_pollfd{.{ .fd = 0, .events = c.POLLIN, .revents = 0 }};
            const rc = c.poll(&fds, 1, timeout_ms);
            if (rc == 0) return error.Timeout;
            if (rc < 0) return error.ReadFailed;
        }
        const stdin = std.Io.File.stdin();
        const n = stdin.readStreaming(self.io, &.{buf}) catch |err| {
            if (err == error.EndOfStream) return 0;
            return error.ReadFailed;
        };
        return n;
    }

    fn writeFn(ctx: *anyopaque, bytes: []const u8) Stream.WriteError!void {
        const self: *StdioStream = @ptrCast(@alignCast(ctx));
        const stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
    }
};

// ── Request/response correlator ──

pub const Correlator = struct {
    allocator: Allocator,
    stream: Stream,
    /// Raw bytes read but not yet consumed as a full line.
    line_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Whole lines that arrived while we were waiting for a sampling
    /// response — handed back to the main loop in arrival order.
    queued: std.ArrayListUnmanaged([]u8) = .empty,
    /// Ids for OUR outgoing requests. The server never reuses client ids
    /// (responses echo theirs verbatim), so a private counter cannot clash.
    next_id: u64 = 1,
    /// Did the client declare the `sampling` capability during initialize?
    client_supports_sampling: bool = false,
    eof: bool = false,

    pub fn init(allocator: Allocator, stream: Stream) Correlator {
        return .{ .allocator = allocator, .stream = stream };
    }

    pub fn deinit(self: *Correlator) void {
        for (self.queued.items) |q| self.allocator.free(q);
        self.queued.deinit(self.allocator);
        self.line_buf.deinit(self.allocator);
    }

    /// Main-loop read: previously queued lines first (in order), then fresh
    /// input. Returns an owned line without its trailing newline (caller
    /// frees), or null at end of stream.
    pub fn nextLine(self: *Correlator) Allocator.Error!?[]u8 {
        if (self.queued.items.len > 0) return self.queued.orderedRemove(0);
        return self.readLine(-1) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // A blocking read only times out on stream failure; treat both
            // as end-of-input so the serve loop shuts down cleanly.
            error.Timeout, error.ReadFailed => null,
        };
    }

    /// Send a JSON-RPC request to the client and block until the response
    /// with the matching id arrives. Interleaved incoming messages are
    /// queued for `nextLine`. Returns the raw response line (owned).
    pub fn request(self: *Correlator, method: []const u8, params: anytype, timeout_ms: i32) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        const msg = try std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .method = method,
            .params = params,
        }, .{});
        defer self.allocator.free(msg);
        try self.stream.write(msg);
        try self.stream.write("\n");

        const deadline = nowMs() + timeout_ms;
        while (true) {
            const remaining = deadline - nowMs();
            if (remaining <= 0) return error.Timeout;
            const budget: i32 = @intCast(@min(remaining, 2_000_000_000));
            const line = (try self.readLine(budget)) orelse return error.EndOfStream;
            if (isResponseWithId(self.allocator, line, id)) return line;
            if (line.len == 0) {
                self.allocator.free(line);
                continue;
            }
            try self.queued.append(self.allocator, line);
        }
    }

    /// Read one newline-terminated line (owned, newline stripped). Buffers
    /// partial chunks; a final unterminated line is flushed at EOF.
    fn readLine(self: *Correlator, timeout_ms: i32) (Stream.ReadError || Allocator.Error)!?[]u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.line_buf.items, '\n')) |nl| {
                var end = nl;
                if (end > 0 and self.line_buf.items[end - 1] == '\r') end -= 1;
                const line = try self.allocator.dupe(u8, self.line_buf.items[0..end]);
                const remaining = self.line_buf.items.len - (nl + 1);
                std.mem.copyForwards(u8, self.line_buf.items[0..remaining], self.line_buf.items[nl + 1 ..]);
                self.line_buf.shrinkRetainingCapacity(remaining);
                return line;
            }
            if (self.eof) {
                if (self.line_buf.items.len > 0) {
                    const line = try self.allocator.dupe(u8, self.line_buf.items);
                    self.line_buf.clearRetainingCapacity();
                    return line;
                }
                return null;
            }
            var chunk: [4096]u8 = undefined;
            const n = try self.stream.read(&chunk, timeout_ms);
            if (n == 0) {
                self.eof = true;
                continue;
            }
            try self.line_buf.appendSlice(self.allocator, chunk[0..n]);
        }
    }
};

/// True iff `line` is a JSON-RPC *response* (no "method") whose id equals
/// ours and which carries a result or error. Anything else — client
/// requests, notifications, responses to other ids, garbage — is not ours.
fn isResponseWithId(allocator: Allocator, line: []const u8, id: u64) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const obj = parsed.value.object;
    if (obj.get("method") != null) return false;
    const idv = obj.get("id") orelse return false;
    const got: u64 = switch (idv) {
        .integer => |n| if (n >= 0) @intCast(n) else return false,
        else => return false,
    };
    if (got != id) return false;
    return obj.get("result") != null or obj.get("error") != null;
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
}

// ── Opt-in gate ──

/// Sampling only fires when the user explicitly opts in: MEMXT_SAMPLING=1
/// (or true/on). Client capability alone is not consent to spend its tokens.
pub fn enabledByEnv() bool {
    const raw = c.getenv("MEMXT_SAMPLING") orelse return false;
    const v = std.mem.span(raw);
    return std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on");
}

// ── Fact extraction via the client's model ──

const SYSTEM_PROMPT = "You extract durable facts from engineering notes for a local long-term memory store. Reply with only the requested FACT/SUMMARY lines — no prose, no code fences.";

const PROMPT_FMT =
    \\Extract up to 5 durable facts from the note below — decisions, preferences,
    \\constraints, identities. Skip anything transient. Reply with one line per fact:
    \\FACT: <subject> | <key> | <value>
    \\Then exactly one final line:
    \\SUMMARY: <one-line summary of the note>
    \\If there are no durable facts, reply with only the SUMMARY line.
    \\
    \\Note:
    \\{s}
;

/// Ask the client model for subject/key/value triples (+ one-line summary)
/// for `content`. Returns extracted facts ready for facts.ingestExtracted.
/// Every failure mode (no response, timeout, refusal, unparseable text)
/// surfaces as an error so the caller silently keeps the heuristic path.
pub fn extractViaSampling(corr: *Correlator, content: []const u8, allocator: Allocator) ![]facts.Extracted {
    const body = if (content.len > MAX_CONTENT_CHARS) content[0..MAX_CONTENT_CHARS] else content;
    const prompt = try std.fmt.allocPrint(allocator, PROMPT_FMT, .{body});
    defer allocator.free(prompt);

    const line = try corr.request("sampling/createMessage", .{
        .messages = .{
            .{ .role = "user", .content = .{ .@"type" = "text", .text = prompt } },
        },
        .systemPrompt = SYSTEM_PROMPT,
        .includeContext = "none",
        .maxTokens = 400,
        .modelPreferences = .{ .speedPriority = 0.8, .intelligencePriority = 0.4 },
    }, DEFAULT_TIMEOUT_MS);
    defer corr.allocator.free(line);

    const text = (try responseText(line, allocator)) orelse return error.NoSampledText;
    defer allocator.free(text);
    return parseTriples(text, allocator);
}

/// Pull the assistant text out of a createMessage response line. Null for
/// error responses or non-text content (caller falls back to heuristics).
pub fn responseText(line: []const u8, allocator: Allocator) Allocator.Error!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    const content = result.object.get("content") orelse return null;
    switch (content) {
        // Spec shape: a single {type:"text",text:"…"} object…
        .object => |o| {
            if (o.get("text")) |t| {
                if (t == .string) return try allocator.dupe(u8, t.string);
            }
        },
        // …but tolerate clients that send an array of content blocks.
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .object) continue;
                if (item.object.get("text")) |t| {
                    if (t == .string) return try allocator.dupe(u8, t.string);
                }
            }
        },
        else => {},
    }
    return null;
}

/// Parse "FACT: subject | key | value" lines (max 5) and one "SUMMARY: …"
/// into facts.Extracted triples. Malformed lines are skipped, never fatal.
pub fn parseTriples(text: []const u8, allocator: Allocator) ![]facts.Extracted {
    var out: std.ArrayListUnmanaged(facts.Extracted) = .empty;
    errdefer {
        for (out.items) |e| {
            allocator.free(e.subject);
            allocator.free(e.predicate);
            allocator.free(e.object);
        }
        out.deinit(allocator);
    }

    var fact_count: usize = 0;
    var have_summary = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, line, "- ")) line = std.mem.trimStart(u8, line[2..], &std.ascii.whitespace);

        if (std.ascii.startsWithIgnoreCase(line, "FACT:")) {
            if (fact_count >= 5) continue;
            const rest = line["FACT:".len..];
            var it = std.mem.splitScalar(u8, rest, '|');
            const subject = std.mem.trim(u8, it.next() orelse continue, &std.ascii.whitespace);
            const predicate = std.mem.trim(u8, it.next() orelse continue, &std.ascii.whitespace);
            const object = std.mem.trim(u8, it.next() orelse continue, &std.ascii.whitespace);
            if (subject.len == 0 or subject.len > 120) continue;
            if (predicate.len == 0 or predicate.len > 80) continue;
            if (object.len == 0 or object.len > 240) continue;
            try out.append(allocator, .{
                .subject = try allocator.dupe(u8, subject),
                .predicate = try allocator.dupe(u8, predicate),
                .object = try allocator.dupe(u8, object),
                .confidence = 0.8,
            });
            fact_count += 1;
        } else if (std.ascii.startsWithIgnoreCase(line, "SUMMARY:")) {
            if (have_summary) continue;
            const summary = std.mem.trim(u8, line["SUMMARY:".len..], &std.ascii.whitespace);
            if (summary.len < 8 or summary.len > 300) continue;
            try out.append(allocator, .{
                .subject = try allocator.dupe(u8, "memory"),
                .predicate = try allocator.dupe(u8, "summary"),
                .object = try allocator.dupe(u8, summary),
                .confidence = 0.7,
            });
            have_summary = true;
        }
    }

    return out.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════
// Automated Testing Suite
// ═══════════════════════════════════════════════════════════════════

/// Scripted stream for tests: reads come from a fixed input (optionally in
/// tiny chunks to exercise partial framing); writes are captured; exhausting
/// the input yields EOF or Timeout depending on the scenario.
const TestStream = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize = 0,
    chunk_max: usize = 4096,
    on_exhausted: enum { eof, timeout } = .eof,
    out: std.ArrayListUnmanaged(u8) = .empty,

    fn stream(self: *TestStream) Stream {
        return .{ .ctx = self, .readFn = readFn, .writeFn = writeFn };
    }

    fn deinit(self: *TestStream) void {
        self.out.deinit(self.allocator);
    }

    fn readFn(ctx: *anyopaque, buf: []u8, timeout_ms: i32) Stream.ReadError!usize {
        _ = timeout_ms;
        const self: *TestStream = @ptrCast(@alignCast(ctx));
        if (self.pos >= self.input.len) {
            return switch (self.on_exhausted) {
                .eof => 0,
                .timeout => error.Timeout,
            };
        }
        const n = @min(buf.len, @min(self.chunk_max, self.input.len - self.pos));
        @memcpy(buf[0..n], self.input[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn writeFn(ctx: *anyopaque, bytes: []const u8) Stream.WriteError!void {
        const self: *TestStream = @ptrCast(@alignCast(ctx));
        self.out.appendSlice(self.allocator, bytes) catch return error.WriteFailed;
    }
};

test "correlator: line framing across partial reads, CRLF, and EOF flush" {
    const allocator = std.testing.allocator;
    var ts = TestStream{
        .allocator = allocator,
        .input = "{\"a\":1}\n{\"b\":2}\r\ntail-no-newline",
        .chunk_max = 3, // force many partial reads through the frame buffer
    };
    defer ts.deinit();
    var corr = Correlator.init(allocator, ts.stream());
    defer corr.deinit();

    const l1 = (try corr.nextLine()).?;
    defer allocator.free(l1);
    try std.testing.expectEqualStrings("{\"a\":1}", l1);

    const l2 = (try corr.nextLine()).?;
    defer allocator.free(l2);
    try std.testing.expectEqualStrings("{\"b\":2}", l2);

    const l3 = (try corr.nextLine()).?;
    defer allocator.free(l3);
    try std.testing.expectEqualStrings("tail-no-newline", l3);

    try std.testing.expect((try corr.nextLine()) == null);
}

test "correlator: request matches its response id and queues interleaved messages" {
    const allocator = std.testing.allocator;
    var ts = TestStream{
        .allocator = allocator,
        .input = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\"}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"FACT: a | b | c\"}}}\n",
    };
    defer ts.deinit();
    var corr = Correlator.init(allocator, ts.stream());
    defer corr.deinit();

    const resp = try corr.request("sampling/createMessage", .{ .maxTokens = 10 }, 5_000);
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "assistant") != null);

    // Outgoing request was framed as one newline-terminated JSON line with our id.
    try std.testing.expect(std.mem.indexOf(u8, ts.out.items, "\"method\":\"sampling/createMessage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts.out.items, "\"id\":1") != null);
    try std.testing.expectEqual(@as(u8, '\n'), ts.out.items[ts.out.items.len - 1]);

    // Interleaved messages survive, in arrival order, for the main loop.
    const q1 = (try corr.nextLine()).?;
    defer allocator.free(q1);
    try std.testing.expect(std.mem.indexOf(u8, q1, "\"id\":42") != null);
    const q2 = (try corr.nextLine()).?;
    defer allocator.free(q2);
    try std.testing.expect(std.mem.indexOf(u8, q2, "notifications/cancelled") != null);
}

test "correlator: a response to a DIFFERENT id is not swallowed as ours" {
    const allocator = std.testing.allocator;
    var ts = TestStream{
        .allocator = allocator,
        .input = "{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"ok\"}}}\n",
    };
    defer ts.deinit();
    var corr = Correlator.init(allocator, ts.stream());
    defer corr.deinit();

    const resp = try corr.request("sampling/createMessage", .{}, 5_000);
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);

    const stray = (try corr.nextLine()).?;
    defer allocator.free(stray);
    try std.testing.expect(std.mem.indexOf(u8, stray, "\"id\":99") != null);
}

test "correlator: timeout falls back without losing queued messages" {
    const allocator = std.testing.allocator;
    var ts = TestStream{
        .allocator = allocator,
        .input = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}\n",
        .on_exhausted = .timeout, // input dries up but the stream stays open
    };
    defer ts.deinit();
    var corr = Correlator.init(allocator, ts.stream());
    defer corr.deinit();

    try std.testing.expectError(error.Timeout, corr.request("sampling/createMessage", .{}, 50));

    // The interleaved ping was queued, not dropped, despite the timeout.
    const q = (try corr.nextLine()).?;
    defer allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "\"method\":\"ping\"") != null);
}

test "sampling: parse FACT/SUMMARY triples from model text" {
    const allocator = std.testing.allocator;
    const text = "Here you go:\n" ++
        "FACT: database | engine | SQLite\n" ++
        "- FACT: team | prefers | small PRs\n" ++
        "FACT: malformed line without pipes\n" ++
        "FACT:  | empty | subject\n" ++
        "SUMMARY: Chose SQLite for the palace store.\n";
    const got = try parseTriples(text, allocator);
    defer facts.freeExtracted(got, allocator);

    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("database", got[0].subject);
    try std.testing.expectEqualStrings("engine", got[0].predicate);
    try std.testing.expectEqualStrings("SQLite", got[0].object);
    try std.testing.expectEqualStrings("team", got[1].subject);
    try std.testing.expectEqualStrings("summary", got[2].predicate);
    try std.testing.expectEqualStrings("Chose SQLite for the palace store.", got[2].object);
}

test "sampling: response text extraction tolerates shapes and rejects errors" {
    const allocator = std.testing.allocator;

    const ok = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"role\":\"assistant\",\"model\":\"local\",\"content\":{\"type\":\"text\",\"text\":\"hi\"}}}";
    const t1 = (try responseText(ok, allocator)).?;
    defer allocator.free(t1);
    try std.testing.expectEqualStrings("hi", t1);

    const arr = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"blocks\"}]}}";
    const t2 = (try responseText(arr, allocator)).?;
    defer allocator.free(t2);
    try std.testing.expectEqualStrings("blocks", t2);

    const err_resp = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1,\"message\":\"user rejected\"}}";
    try std.testing.expect((try responseText(err_resp, allocator)) == null);
}
