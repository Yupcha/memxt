// ═══════════════════════════════════════════════════════════════════
// memxt/serve.zig — Localhost monitor UI + tiny JSON API
//
// Bound to 127.0.0.1 only. No auth (local machine). Static HTML is
// embedded so the binary stays dependency-free.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const config = @import("config.zig");
const db = @import("db.zig");
const palace_mod = @import("palace.zig");
const inspect_mod = @import("inspect.zig");
const searcher = @import("searcher.zig");
const embedder = @import("embedder.zig");
const wakeup = @import("wakeup.zig");
const dream_mod = @import("dream.zig");
const facts_mod = @import("facts.zig");
const profile_mod = @import("profile.zig");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
});

const UI_HTML = @embedFile("ui.html");

pub const ServeOptions = struct {
    port: u16 = 8765,
    host: []const u8 = "127.0.0.1",
};

pub fn run(cfg: *const config.Config, opts: ServeOptions, allocator: Allocator) !void {
    var database = try db.Database.open(cfg.database_path.ptr);
    defer database.close();
    database.createPalaceSchema();

    const sock: c_int = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (sock < 0) return error.SocketFailed;
    defer _ = c.close(sock);

    var yes: c_int = 1;
    _ = c.setsockopt(sock, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));

    var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(opts.port);
    // Force localhost only.
    addr.sin_addr.s_addr = c.inet_addr("127.0.0.1");

    if (c.bind(sock, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) < 0) return error.BindFailed;
    if (c.listen(sock, 16) < 0) return error.ListenFailed;

    std.debug.print(
        \\🏛️  memxt serve — local monitor
        \\  URL:  http://127.0.0.1:{d}/
        \\  DB:   {s}
        \\  API:  /api/inspect  /api/search?q=…  /api/wake-up  /api/dream
        \\  Ctrl+C to stop. Bound to localhost only.
        \\
    , .{ opts.port, cfg.database_path });

    while (true) {
        var client_addr: c.sockaddr_in = undefined;
        var len: c.socklen_t = @sizeOf(c.sockaddr_in);
        const client = c.accept(sock, @ptrCast(&client_addr), &len);
        if (client < 0) continue;
        handleClient(client, &database, cfg, allocator) catch {};
        _ = c.close(client);
    }
}

fn handleClient(client: c_int, database: *db.Database, cfg: *const config.Config, allocator: Allocator) !void {
    var buf: [8192]u8 = undefined;
    const n = c.read(client, &buf, buf.len);
    if (n <= 0) return;
    const req = buf[0..@intCast(n)];

    // Parse request line: METHOD PATH HTTP/…
    var line_end: usize = 0;
    while (line_end < req.len and req[line_end] != '\n') : (line_end += 1) {}
    const req_line = std.mem.trim(u8, req[0..line_end], " \r");
    var it = std.mem.tokenizeScalar(u8, req_line, ' ');
    const method = it.next() orelse return;
    const path_full = it.next() orelse return;
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "POST")) {
        try writeResponse(client, 405, "text/plain", "method not allowed");
        return;
    }

    var path = path_full;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, path_full, '?')) |q| {
        path = path_full[0..q];
        query = path_full[q + 1 ..];
    }

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        try writeResponse(client, 200, "text/html; charset=utf-8", UI_HTML);
    } else if (std.mem.eql(u8, path, "/api/inspect")) {
        const text = try inspect_mod.render(database, cfg.database_path, allocator);
        defer allocator.free(text);
        try writeResponse(client, 200, "text/plain; charset=utf-8", text);
    } else if (std.mem.eql(u8, path, "/api/stats")) {
        var pal = palace_mod.Palace.init(database, allocator);
        const text = try pal.stats(allocator);
        defer allocator.free(text);
        try writeResponse(client, 200, "text/plain; charset=utf-8", text);
    } else if (std.mem.eql(u8, path, "/api/wake-up")) {
        const wing = queryParam(query, "wing") orelse (if (!std.mem.eql(u8, cfg.default_wing, "default")) cfg.default_wing else null);
        const text = try wakeup.generate(database, wing, allocator);
        defer allocator.free(text);
        try writeResponse(client, 200, "text/plain; charset=utf-8", text);
    } else if (std.mem.eql(u8, path, "/api/search")) {
        const q = queryParam(query, "q") orelse {
            try writeResponse(client, 400, "text/plain", "missing q=");
            return;
        };
        const q_decoded = try urlDecodeAlloc(q, allocator);
        defer allocator.free(q_decoded);
        const mode_s = queryParam(query, "mode") orelse "hybrid";
        const mode = searcher.SearchMode.parse(mode_s) orelse .hybrid;
        const wing = queryParam(query, "wing") orelse (if (!std.mem.eql(u8, cfg.default_wing, "default")) cfg.default_wing else null);

        if (!embedder.isReady()) embedder.initGlobal(cfg.model_path) catch {};
        var pal = palace_mod.Palace.init(database, allocator);

        var q_vec: []const f32 = &[_]f32{};
        var owned = false;
        if (mode != .facts and embedder.isReady()) {
            q_vec = embedder.embed(q_decoded, allocator) catch &[_]f32{};
            if (q_vec.len > 0) owned = true;
        }
        defer if (owned) allocator.free(q_vec);

        // searcher only uses Io when use_llm_reranker (off here).
        const results = searcher.search(&pal, q_decoded, q_vec, .{
            .limit = 10,
            .wing = wing,
            .mode = mode,
        }, allocator, undefined) catch {
            try writeResponse(client, 500, "text/plain", "search failed");
            return;
        };
        defer {
            for (results) |r| {
                allocator.free(r.content);
                allocator.free(r.source_path);
                allocator.free(r.wing_name);
                allocator.free(r.room_name);
            }
            allocator.free(results);
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, "[\n");
        for (results, 0..) |r, i| {
            if (i > 0) try out.appendSlice(allocator, ",\n");
            const esc = try jsonEscape(r.content, allocator);
            defer allocator.free(esc);
            const jline = try std.fmt.allocPrint(allocator,
                \\  {{"id":{d},"wing":"{s}","room":"{s}","score":{d:.4},"content":"{s}"}}
            , .{ r.drawer_id, r.wing_name, r.room_name, r.score, esc });
            defer allocator.free(jline);
            try out.appendSlice(allocator, jline);
        }
        try out.appendSlice(allocator, "\n]\n");
        try writeResponse(client, 200, "application/json; charset=utf-8", out.items);
    } else if (std.mem.eql(u8, path, "/api/dream")) {
        if (!embedder.isReady()) embedder.initGlobal(cfg.model_path) catch {};
        const report = try dream_mod.run(database, .{}, allocator);
        const text = try dream_mod.formatReport(report, allocator);
        defer allocator.free(text);
        try writeResponse(client, 200, "text/plain; charset=utf-8", text);
    } else if (std.mem.eql(u8, path, "/api/profile")) {
        const wing = queryParam(query, "wing") orelse cfg.default_wing;
        var pal = palace_mod.Palace.init(database, allocator);
        const wid = pal.getWingId(wing) orelse {
            try writeResponse(client, 200, "text/plain", "(no wing yet)");
            return;
        };
        const text = try profile_mod.renderBrief(database, wid, wing, allocator);
        defer allocator.free(text);
        try writeResponse(client, 200, "text/plain; charset=utf-8", text);
    } else if (std.mem.eql(u8, path, "/api/facts")) {
        const wing = queryParam(query, "wing") orelse cfg.default_wing;
        var pal = palace_mod.Palace.init(database, allocator);
        const wid = pal.getWingId(wing) orelse {
            try writeResponse(client, 200, "application/json", "[]");
            return;
        };
        const fl = try facts_mod.listActive(database, wid, 50, allocator);
        defer facts_mod.freeFacts(fl, allocator);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, "[\n");
        for (fl, 0..) |f, i| {
            if (i > 0) try out.appendSlice(allocator, ",\n");
            const line = try std.fmt.allocPrint(allocator,
                \\  {{"id":{d},"s":"{s}","p":"{s}","o":"{s}","conf":{d:.2}}}
            , .{ f.id, f.subject, f.predicate, f.object, f.confidence });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
        try out.appendSlice(allocator, "\n]\n");
        try writeResponse(client, 200, "application/json; charset=utf-8", out.items);
    } else {
        try writeResponse(client, 404, "text/plain", "not found");
    }
}

fn writeResponse(client: c_int, status: u16, content_type: []const u8, body: []const u8) !void {
    const reason: []const u8 = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        else => "Error",
    };
    var hdr: [512]u8 = undefined;
    const h = try std.fmt.bufPrint(&hdr, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{
        status, reason, content_type, body.len,
    });
    _ = c.write(client, h.ptr, h.len);
    if (body.len > 0) _ = c.write(client, body.ptr, body.len);
}

fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            const k = pair[0..eq];
            const v = pair[eq + 1 ..];
            if (std.mem.eql(u8, k, key)) return v;
        }
    }
    return null;
}

fn urlDecodeAlloc(s: []const u8, allocator: Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, s[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, hi);
            i += 3;
        } else if (s[i] == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn jsonEscape(s: []const u8, allocator: Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) continue;
                try out.append(allocator, ch);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}
