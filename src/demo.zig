// ═══════════════════════════════════════════════════════════════════
// memxt/demo.zig — `memxt demo`: the first-minute experience
//
// A self-contained, ~60-second tour that runs against a THROWAWAY palace
// (a temp db, deleted afterwards unless --keep) so it never touches the
// user's real memory. Three acts:
//
//   1. "Yesterday" — a simulated session stores three project decisions.
//   2. "Today"     — a fresh session wakes up in milliseconds and recalls
//                    each decision from a PARAPHRASED question (no shared
//                    keywords — this is semantic recall, not grep).
//   3. "Your repo" — mines the current directory live and shows what the
//                    next session would wake up already knowing.
//
// Everything is timed with a monotonic clock and printed honestly; the
// recall checks show real top-1 hits from the real search pipeline.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const config = @import("config.zig");
const db = @import("db.zig");
const palace_mod = @import("palace.zig");
const miner = @import("miner.zig");
const searcher = @import("searcher.zig");
const embedder = @import("embedder.zig");
const wakeup = @import("wakeup.zig");
const packer = @import("packer.zig");

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

// ── Monotonic timing ──

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

fn ms(from: u64, to: u64) f64 {
    return @as(f64, @floatFromInt(to - from)) / 1_000_000.0;
}

/// Stage pacing: the work is near-instant, but humans (and screen
/// recordings) need a beat between lines to follow the story.
fn pause(msec: u32) void {
    _ = c.usleep(msec * 1000);
}

/// MEMXT_DEMO_STAGED=1 (used by the recording tape) clears the screen
/// between acts so each renders like a slide instead of scrolling.
fn nextStage(staged: bool, hold_msec: u32) void {
    pause(hold_msec);
    if (staged) std.debug.print("\x1b[2J\x1b[H", .{});
}

// ── ANSI styling (disabled when stderr is not a tty) ──

const Style = struct {
    bold: []const u8 = "",
    dim: []const u8 = "",
    green: []const u8 = "",
    cyan: []const u8 = "",
    yellow: []const u8 = "",
    reset: []const u8 = "",

    fn detect() Style {
        if (c.isatty(2) == 1) return .{
            .bold = "\x1b[1m",
            .dim = "\x1b[2m",
            .green = "\x1b[32m",
            .cyan = "\x1b[36m",
            .yellow = "\x1b[33m",
            .reset = "\x1b[0m",
        };
        return .{};
    }
};

// ── The simulated "yesterday" session ──

const Decision = struct {
    text: []const u8,
    /// Deliberately shares (almost) no keywords with the stored text.
    paraphrase: []const u8,
    /// Substring that must appear in the top-1 hit for the ✓.
    expect: []const u8,
};

const decisions = [_]Decision{
    .{
        .text = "Decision: the cart cap is 37 items per order. Anything larger trips the fraud checks downstream — do not raise it without talking to payments.",
        .paraphrase = "maximum number of items allowed in one basket",
        .expect = "37",
    },
    .{
        .text = "Decision: Redis is banned in this codebase. We tried it twice and cache invalidation bugs ate two weekends. Do not reintroduce it.",
        .paraphrase = "can I speed this up with a caching layer?",
        .expect = "Redis",
    },
    .{
        .text = "Decision: we chose SQLite over Postgres for local state — zero ops, a single file, and WAL gives us all the concurrency we need.",
        .paraphrase = "which storage engine did we settle on, and why?",
        .expect = "SQLite",
    },
};

const DEMO_WING = "demo-project";

pub fn run(cfg: *const config.Config, keep: bool, allocator: Allocator, io: std.Io) !void {
    const s = Style.detect();
    const staged = c.getenv("MEMXT_DEMO_STAGED") != null;

    // Throwaway palace in TMPDIR — the user's real palace is never touched.
    const tmpdir: []const u8 = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    var path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&path_buf, "{s}/memxt-demo-{d}.db", .{
        std.mem.trimEnd(u8, tmpdir, "/"), c.getpid(),
    }) catch {
        std.debug.print("demo: TMPDIR path too long\n", .{});
        return;
    };

    std.debug.print(
        "\n{s}🏛  memxt demo{s} {s}— a 60-second tour on a throwaway palace (your real memory is untouched){s}\n\n",
        .{ s.bold, s.reset, s.dim, s.reset },
    );

    std.debug.print("{s}loading the local embedding model…{s}\n\n", .{ s.dim, s.reset });
    embedder.initGlobal(cfg.model_path) catch {
        std.debug.print(
            "demo: could not load the embedding model at '{s}'.\n" ++
                "      Run the installer (curl … | bash) or point MEMXT_MODEL at a MiniLM GGUF.\n",
            .{cfg.model_path},
        );
        return;
    };
    defer embedder.deinitGlobal();

    var database = try db.Database.open(db_path.ptr);
    database.createPalaceSchema();
    var pal = palace_mod.Palace.init(&database, allocator);

    defer {
        database.close();
        if (!keep) {
            var buf: [520]u8 = undefined;
            _ = c.remove(db_path.ptr);
            for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
                if (std.fmt.bufPrintZ(&buf, "{s}{s}", .{ db_path, suffix })) |p| {
                    _ = c.remove(p.ptr);
                } else |_| {}
            }
        } else {
            std.debug.print("{s}(kept demo palace at {s} — inspect it with MEMXT_DB={s} memxt inspect){s}\n", .{ s.dim, db_path, db_path, s.reset });
        }
    }

    // ── Act 1: yesterday's session ──
    std.debug.print("{s}ACT 1 — yesterday{s}  {s}(a session where you explained three decisions){s}\n\n", .{ s.bold, s.reset, s.dim, s.reset });

    const t_store0 = nowNs();
    for (decisions) |d| {
        _ = miner.storeMemory(&pal, d.text, DEMO_WING, "decisions", "demo", allocator) catch |err| {
            std.debug.print("demo: store failed: {}\n", .{err});
            return;
        };
        std.debug.print("  {s}stored{s}  \"{s}\"\n", .{ s.cyan, s.reset, firstLine(d.text) });
        pause(500);
    }
    const t_store1 = nowNs();
    std.debug.print("\n  {s}3 memories embedded locally in {d:.0} ms — no network, no API key.{s}\n\n", .{ s.dim, ms(t_store0, t_store1), s.reset });

    // ── Act 2: today — a brand new session ──
    nextStage(staged, 1400);
    std.debug.print("{s}ACT 2 — today{s}  {s}(new session; normally your agent remembers none of this){s}\n\n", .{ s.bold, s.reset, s.dim, s.reset });

    const t_wake0 = nowNs();
    const brief = try wakeup.generate(&database, DEMO_WING, allocator);
    const t_wake1 = nowNs();
    defer allocator.free(brief);

    std.debug.print("  wake-up brief assembled in {s}{d:.1} ms{s} (~{d} tokens):\n\n", .{ s.green, ms(t_wake0, t_wake1), s.reset, packer.estimateTokens(brief) });
    printIndented(brief, "    ");

    nextStage(staged, 2600);
    std.debug.print("{s}Now ask in different words{s} {s}than were ever stored:{s}\n\n", .{ s.bold, s.reset, s.dim, s.reset });
    pause(700);

    var recalled: u32 = 0;
    for (decisions) |d| {
        const t_q0 = nowNs();
        const qvec = embedder.embed(d.paraphrase, allocator) catch &[_]f32{};
        defer if (qvec.len > 0) allocator.free(qvec);
        const results = searcher.search(&pal, d.paraphrase, qvec, .{ .limit = 3, .wing = DEMO_WING }, allocator, io) catch &[_]palace_mod.SearchResult{};
        const t_q1 = nowNs();
        defer {
            for (results) |r| {
                allocator.free(r.content);
                allocator.free(r.source_path);
                allocator.free(r.wing_name);
                allocator.free(r.room_name);
            }
            allocator.free(results);
        }

        pause(600);
        std.debug.print("  {s}?{s} \"{s}\"\n", .{ s.yellow, s.reset, d.paraphrase });
        pause(450);
        if (results.len > 0 and std.mem.indexOf(u8, results[0].content, d.expect) != null) {
            recalled += 1;
            std.debug.print("  {s}✓{s} {s}  {s}({d:.1} ms){s}\n\n", .{ s.green, s.reset, firstLine(results[0].content), s.dim, ms(t_q0, t_q1), s.reset });
        } else if (results.len > 0) {
            std.debug.print("  {s}~{s} top hit: {s}\n\n", .{ s.yellow, s.reset, firstLine(results[0].content) });
        } else {
            std.debug.print("  {s}✗ no hit{s}\n\n", .{ s.yellow, s.reset });
        }
    }
    pause(500);
    std.debug.print("  {s}{d}/3 recalled from paraphrases — semantic memory, not grep.{s}\n\n", .{ s.bold, recalled, s.reset });

    // ── Act 3: your actual repo ──
    nextStage(staged, 2200);
    std.debug.print("{s}ACT 3 — your repo{s}  {s}(mining the current directory into the throwaway palace){s}\n\n", .{ s.bold, s.reset, s.dim, s.reset });

    const t_mine0 = nowNs();
    const stats = miner.mineDirectory(&pal, ".", .{ .wing_name = cfg.default_wing, .max_files = 15 }, io, allocator) catch miner.MineStats{};
    const t_mine1 = nowNs();

    if (stats.drawers_created > 0) {
        std.debug.print("  {s}mined{s} {d} files (demo caps at 15 — `memxt mine .` does them all) → {d} memories ({d:.1} KB) in {s}{d:.0} ms{s}\n\n", .{
            s.cyan,                                                s.reset,
            stats.files_processed,                                 stats.drawers_created,
            @as(f64, @floatFromInt(stats.bytes_processed)) / 1024, s.green,
            ms(t_mine0, t_mine1),                                  s.reset,
        });

        const repo_brief = try wakeup.generate(&database, cfg.default_wing, allocator);
        defer allocator.free(repo_brief);
        const brief_tokens = packer.estimateTokens(repo_brief);
        const repaste_tokens = stats.bytes_processed / 4;

        std.debug.print("  Next session, your agent would wake up already knowing this repo:\n", .{});
        std.debug.print("    {s}re-pasting what was just mined ≈ {d} tokens; the wake-up brief ≈ {d} tokens.{s}\n\n", .{ s.dim, repaste_tokens, brief_tokens, s.reset });
        std.debug.print("  Try it in your own words:  {s}memxt search \"<a decision you remember making>\"{s}\n\n", .{ s.bold, s.reset });
    } else {
        std.debug.print("  {s}(nothing minable in the current directory — run the demo inside a repo to see this act){s}\n\n", .{ s.dim, s.reset });
    }

    // ── CTA ──
    pause(1200);
    std.debug.print("{s}────────────────────────────────────────────────────{s}\n", .{ s.dim, s.reset });
    std.debug.print("{s}This palace was a throwaway{s} — your real one lives at ~/.memxt.\nMake it permanent:\n\n", .{ s.dim, s.reset });
    std.debug.print("  {s}memxt adopt --write{s}          {s}wire Claude Code / Codex / Cursor / Grok + mine this repo{s}\n", .{ s.bold, s.reset, s.dim, s.reset });
    std.debug.print("  {s}/plugin install memxt{s}        {s}inside Claude Code (marketplace: Yupcha/memxt){s}\n\n", .{ s.bold, s.reset, s.dim, s.reset });
}

// ── helpers ──

fn firstLine(text: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var line = text[0..nl];
    if (line.len > 96) {
        line = line[0..96];
        // Don't cut a UTF-8 sequence mid-byte.
        while (line.len > 0 and (line[line.len - 1] & 0xC0) == 0x80) line = line[0 .. line.len - 1];
    }
    return std.mem.trimEnd(u8, line, " ");
}

fn printIndented(text: []const u8, indent: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        std.debug.print("{s}{s}\n", .{ indent, line });
    }
}
