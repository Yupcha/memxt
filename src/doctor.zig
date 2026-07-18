// ═══════════════════════════════════════════════════════════════════
// memxt/doctor.zig — `memxt doctor`: self-diagnosis for first-run failures
//
// Checks, in dependency order, everything that commonly breaks between
// `curl | bash` and a working agent memory — and prints the exact fix
// command for each failure instead of a stack trace:
//
//   binary   — version, os/arch
//   model    — the MiniLM GGUF exists and looks plausible
//   embedder — loads and produces a 384-dim vector (timed)
//   palace   — db opens, integrity_check ok, schema version, counts
//   disk     — free space on the palace volume
//   wiring   — which harnesses are connected (Claude plugin / Cursor /
//              Codex / AGENTS.md), reported not judged
//   dreamd   — background consolidator liveness
//
// Exit code 1 when any hard check fails, so CI and installers can gate.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const config = @import("config.zig");
const db = @import("db.zig");
const embedder = @import("embedder.zig");
const dreamd = @import("dreamd.zig");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/statvfs.h");
});

const MODEL_URL = "https://huggingface.co/leliuga/all-MiniLM-L6-v2-GGUF/resolve/main/all-MiniLM-L6-v2.F16.gguf";

const Tally = struct {
    ok: u32 = 0,
    warn: u32 = 0,
    fail: u32 = 0,

    fn pass(self: *Tally, comptime fmt: []const u8, args: anytype) void {
        self.ok += 1;
        std.debug.print("  ✓ " ++ fmt ++ "\n", args);
    }
    fn note(self: *Tally, comptime fmt: []const u8, args: anytype) void {
        self.warn += 1;
        std.debug.print("  ~ " ++ fmt ++ "\n", args);
    }
    fn bad(self: *Tally, comptime fmt: []const u8, args: anytype) void {
        self.fail += 1;
        std.debug.print("  ✗ " ++ fmt ++ "\n", args);
    }
    fn hint(_: *Tally, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("      fix: " ++ fmt ++ "\n", args);
    }
};

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

fn fileSize(path: []const u8) ?u64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: c.struct_stat = undefined;
    if (c.stat(buf[0..path.len :0].ptr, &st) != 0) return null;
    return @intCast(st.st_size);
}

fn countSql(database: *db.Database, sql: []const u8) i64 {
    const stmt = database.prepare(sql) orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return 0;
}

fn firstRowText(database: *db.Database, sql: []const u8, buf: []u8) ?[]const u8 {
    const stmt = database.prepare(sql) orelse return null;
    defer db.finalize(stmt);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const t = db.columnText(stmt, 0) orelse return null;
    if (t.len > buf.len) return null;
    @memcpy(buf[0..t.len], t);
    return buf[0..t.len];
}

fn homePath(allocator: Allocator, comptime rel: []const u8) ?[]u8 {
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.allocPrint(allocator, "{s}" ++ rel, .{std.mem.span(home)}) catch null;
}

fn exists(path: []const u8) bool {
    return fileSize(path) != null;
}

/// Whole-file substring probe for config-wiring detection. Bounded read;
/// missing or huge files simply report "not found".
fn fileContains(path: []const u8, needle: []const u8, allocator: Allocator) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const f = c.fopen(buf[0..path.len :0].ptr, "r") orelse return false;
    defer _ = c.fclose(f);
    const data = allocator.alloc(u8, 256 * 1024) catch return false;
    defer allocator.free(data);
    const n = c.fread(data.ptr, 1, data.len, f);
    return std.mem.indexOf(u8, data[0..n], needle) != null;
}

pub fn run(cfg: *const config.Config, allocator: Allocator) !u8 {
    var t = Tally{};

    std.debug.print("\n🩺 memxt doctor\n\n", .{});

    // ── binary ──
    std.debug.print("binary\n", .{});
    t.pass("memxt v{s} · {s}-{s}", .{ build_options.version, @tagName(builtin.target.cpu.arch), @tagName(builtin.target.os.tag) });

    // ── model ──
    std.debug.print("\nmodel\n", .{});
    var model_ok = false;
    if (fileSize(cfg.model_path)) |size| {
        const mb = @as(f64, @floatFromInt(size)) / (1024 * 1024);
        if (size > 10 * 1024 * 1024) {
            t.pass("embedding model at {s} ({d:.0} MB)", .{ cfg.model_path, mb });
            model_ok = true;
        } else {
            t.bad("model file at {s} is only {d:.1} MB — looks truncated", .{ cfg.model_path, mb });
            t.hint("curl -L -o {s} {s}", .{ cfg.model_path, MODEL_URL });
        }
    } else {
        t.bad("no embedding model at {s}", .{cfg.model_path});
        t.hint("curl -L --create-dirs -o {s} {s}", .{ cfg.model_path, MODEL_URL });
        t.hint("or point MEMXT_MODEL at any MiniLM-L6-v2 384-dim GGUF", .{});
    }

    // ── embedder ──
    std.debug.print("\nembedder\n", .{});
    if (model_ok) {
        const t0 = nowNs();
        if (embedder.initGlobal(cfg.model_path)) |_| {
            defer embedder.deinitGlobal();
            const t1 = nowNs();
            if (embedder.embed("doctor self-test", allocator)) |vec| {
                defer allocator.free(vec);
                const t2 = nowNs();
                if (vec.len == 384) {
                    t.pass("model loads ({d} ms) and embeds 384-dim ({d} ms)", .{ (t1 - t0) / 1_000_000, (t2 - t1) / 1_000_000 });
                } else {
                    t.bad("embedding dim is {d}, schema expects 384 — wrong model?", .{vec.len});
                    t.hint("use all-MiniLM-L6-v2 (384-dim): {s}", .{MODEL_URL});
                }
            } else |err| {
                t.bad("model loaded but embedding failed: {}", .{err});
            }
        } else |err| {
            t.bad("model failed to load: {}", .{err});
            t.hint("re-download it: curl -L -o {s} {s}", .{ cfg.model_path, MODEL_URL });
        }
    } else {
        t.note("skipped (no model)", .{});
    }

    // ── palace ──
    std.debug.print("\npalace\n", .{});
    if (db.Database.open(cfg.database_path.ptr)) |*database_const| {
        var database = database_const.*;
        defer database.close();
        database.createPalaceSchema();

        var row_buf: [128]u8 = undefined;
        const integrity = firstRowText(&database, "PRAGMA integrity_check", &row_buf) orelse "unknown";
        if (std.mem.eql(u8, integrity, "ok")) {
            t.pass("db at {s} — integrity ok", .{cfg.database_path});
        } else {
            t.bad("db integrity check: {s}", .{integrity});
            t.hint("export what's readable (memxt export), move the db aside, re-import", .{});
        }

        var ver_buf: [32]u8 = undefined;
        const uv = firstRowText(&database, "PRAGMA user_version", &ver_buf) orelse "?";
        var jm_buf: [32]u8 = undefined;
        const journal = firstRowText(&database, "PRAGMA journal_mode", &jm_buf) orelse "?";
        const drawers = countSql(&database, "SELECT COUNT(*) FROM drawers");
        const wings = countSql(&database, "SELECT COUNT(*) FROM wings");
        const facts_n = countSql(&database, "SELECT COUNT(*) FROM facts WHERE valid_until IS NULL");
        const vecs = countSql(&database, "SELECT COUNT(*) FROM vec_drawers");
        t.pass("schema v{s} · journal={s} · {d} wings · {d} drawers · {d} active facts · {d} hot vectors", .{ uv, journal, wings, drawers, facts_n, vecs });
        if (drawers == 0) {
            t.note("palace is empty — nothing remembered yet", .{});
            t.hint("memxt demo (60-second tour) · memxt adopt --write (wire + mine this repo)", .{});
        }
    } else |err| {
        t.bad("cannot open palace db at {s}: {}", .{ cfg.database_path, err });
        t.hint("check the directory exists and is writable, or set MEMXT_DB", .{});
    }

    // ── disk ──
    std.debug.print("\ndisk\n", .{});
    {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fs.path.dirname(cfg.database_path) orelse ".";
        if (dir.len < buf.len) {
            @memcpy(buf[0..dir.len], dir);
            buf[dir.len] = 0;
            var vfs: c.struct_statvfs = undefined;
            if (c.statvfs(buf[0..dir.len :0].ptr, &vfs) == 0) {
                const free_bytes = @as(u64, vfs.f_bavail) * vfs.f_frsize;
                const gb = @as(f64, @floatFromInt(free_bytes)) / (1024 * 1024 * 1024);
                if (free_bytes > 1024 * 1024 * 1024) {
                    t.pass("{d:.1} GB free on the palace volume", .{gb});
                } else {
                    t.note("only {d:.2} GB free on the palace volume — dream/quantize may fail", .{gb});
                }
            } else {
                t.note("could not stat the palace volume", .{});
            }
        }
    }

    // ── wiring ──
    std.debug.print("\nwiring  (informational)\n", .{});
    {
        var found: u32 = 0;
        if (homePath(allocator, "/.claude/plugins/config.json")) |p| {
            defer allocator.free(p);
            if (fileContains(p, "memxt", allocator)) {
                t.pass("Claude Code plugin wired ({s})", .{p});
                found += 1;
            }
        }
        if (fileContains(".cursor/mcp.json", "memxt", allocator)) {
            t.pass("Cursor MCP wired (.cursor/mcp.json)", .{});
            found += 1;
        }
        if (homePath(allocator, "/.codex/config.toml")) |p| {
            defer allocator.free(p);
            if (fileContains(p, "memxt", allocator)) {
                t.pass("Codex wired ({s})", .{p});
                found += 1;
            }
        }
        if (exists("AGENTS.md")) {
            t.pass("AGENTS.md present (standing memory rules)", .{});
            found += 1;
        }
        if (found == 0) {
            t.note("no harness wiring detected in this repo/home", .{});
            t.hint("memxt adopt --write · or /plugin install memxt inside Claude Code", .{});
        }
    }

    // ── dreamd ──
    std.debug.print("\ndreamd\n", .{});
    if (homePath(allocator, "/.memxt/dreamd.lock")) |p| {
        defer allocator.free(p);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (p.len < buf.len) {
            @memcpy(buf[0..p.len], p);
            buf[p.len] = 0;
            if (dreamd.lockOwnerPid(buf[0..p.len :0].ptr)) |pid| {
                t.pass("dream daemon running (pid {d})", .{pid});
            } else {
                t.note("dream daemon not running (optional)", .{});
                t.hint("memxt dream --daemon   # sleep-time consolidation", .{});
            }
        }
    }

    // ── summary ──
    std.debug.print("\n{d} ok · {d} warnings · {d} failures\n", .{ t.ok, t.warn, t.fail });
    if (t.fail == 0) {
        std.debug.print("memxt looks healthy. Try: memxt demo\n\n", .{});
    } else {
        std.debug.print("fix the ✗ items above, then re-run memxt doctor.\n\n", .{});
    }
    return if (t.fail == 0) 0 else 1;
}
