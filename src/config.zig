const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

pub const Config = struct {
    default_wing: [:0]const u8 = "default",
    database_path: [:0]const u8 = "memxt.db",
    model_path: [:0]const u8 = "lib/minilm.gguf",
    auto_accept_entities: bool = false,
    ignore_patterns: [][]const u8 = &[_][]const u8{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.ignore_patterns) |pat| {
            allocator.free(pat);
        }
        allocator.free(self.ignore_patterns);

        if (!std.mem.eql(u8, self.default_wing, "default")) {
            allocator.free(self.default_wing);
        }
        if (!std.mem.eql(u8, self.database_path, "memxt.db")) {
            allocator.free(self.database_path);
        }
        if (!std.mem.eql(u8, self.model_path, "lib/minilm.gguf")) {
            allocator.free(self.model_path);
        }
    }
};

/// Attempt to load config from the current directory. Tries `memxt.yaml`
/// first, then falls back to `mempalace.yaml` for drop-in compatibility with the
/// legacy Python package. Returns defaults if neither exists.
pub fn load(allocator: std.mem.Allocator, io: std.Io) !Config {
    var file = std.Io.Dir.cwd().openFile(io, "memxt.yaml", .{}) catch |err1| blk: {
        if (err1 != error.FileNotFound) return err1;
        break :blk std.Io.Dir.cwd().openFile(io, "mempalace.yaml", .{}) catch |err2| {
            if (err2 == error.FileNotFound) return Config{};
            return err2;
        };
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > 10 * 1024 * 1024) return error.FileTooLarge; // arbitrary 10mb limit

    const contents = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(contents);
    
    _ = try file.readPositionalAll(io, contents, 0);

    var cfg = Config{};
    var patterns = std.ArrayListUnmanaged(String).empty;
    defer {
        for (patterns.items) |p| {
            allocator.free(p);
        }
        patterns.deinit(allocator);
    }
    
    var in_ignore_patterns = false;
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        
        if (std.mem.startsWith(u8, line, "default_wing:")) {
            in_ignore_patterns = false;
            const val = extractYamlValue(line["default_wing:".len..]);
            if (val.len > 0 and !std.mem.eql(u8, val, "default")) {
                cfg.default_wing = try allocator.dupeZ(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "database_path:")) {
            in_ignore_patterns = false;
            const val = extractYamlValue(line["database_path:".len..]);
            if (val.len > 0 and !std.mem.eql(u8, val, "memxt.db")) {
                cfg.database_path = try allocator.dupeZ(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "model_path:")) {
            in_ignore_patterns = false;
            const val = extractYamlValue(line["model_path:".len..]);
            if (val.len > 0 and !std.mem.eql(u8, val, "lib/minilm.gguf")) {
                cfg.model_path = try allocator.dupeZ(u8, val);
            }
        } else if (std.mem.startsWith(u8, line, "auto_accept_entities:")) {
            in_ignore_patterns = false;
            const val = extractYamlValue(line["auto_accept_entities:".len..]);
            if (std.mem.eql(u8, val, "true")) cfg.auto_accept_entities = true;
        } else if (std.mem.startsWith(u8, line, "ignore_patterns:")) {
            in_ignore_patterns = true;
        } else if (in_ignore_patterns and std.mem.startsWith(u8, raw_line, "  -")) {
            const val = extractYamlValue(std.mem.trim(u8, raw_line, " \r\t-"));
            if (val.len > 0) {
                try patterns.append(allocator, try allocator.dupe(u8, val));
            }
        } else {
            // Unrecognized line or exiting block
            if (!std.mem.startsWith(u8, raw_line, " ")) {
                in_ignore_patterns = false;
            }
        }
    }
    
    if (patterns.items.len > 0) {
        var ignored = try allocator.alloc([]const u8, patterns.items.len);
        for (patterns.items, 0..) |pat, i| {
            ignored[i] = try allocator.dupe(u8, pat);
        }
        cfg.ignore_patterns = ignored;
    }
    
    return cfg;
}

/// Apply environment-variable overrides. These take precedence over the yaml
/// and defaults, and are how the Claude Code plugin pins a single global palace
/// and model regardless of which project directory the agent is launched in:
///   MEMXT_DB     → database_path
///   MEMXT_MODEL  → model_path
///   MEMXT_WING   → default_wing
pub fn applyEnvOverrides(cfg: *Config, allocator: std.mem.Allocator) void {
    overrideZ(&cfg.database_path, "memxt.db", "MEMXT_DB", allocator);
    overrideZ(&cfg.model_path, "lib/minilm.gguf", "MEMXT_MODEL", allocator);
    overrideZ(&cfg.default_wing, "default", "MEMXT_WING", allocator);
    resolveDatabasePath(cfg, allocator);
    resolveModelPath(cfg, allocator);
    resolveDefaultWing(cfg, allocator);
}

/// The `database_path` default is the *relative* literal "memxt.db", so a bare
/// `memxt search` / `inspect` / `mine` run from any project directory used to
/// silently CREATE a brand-new empty palace right there — littering repos with
/// stray memxt.db files and, far worse, showing the user an empty memory
/// ("0 wings, 0 drawers") as if everything they'd stored was gone. Nothing
/// warned; it just looked like data loss.
///
/// Anchor the unconfigured default to the installer's canonical palace
/// (~/.memxt/palace.db) so bare commands find the real memory from any cwd.
/// An existing ./memxt.db still wins — that's a deliberate project-local
/// palace, and silently re-pointing it at the global one would orphan real data.
fn resolveDatabasePath(cfg: *Config, allocator: std.mem.Allocator) void {
    // Explicitly configured (yaml or MEMXT_DB) — never second-guess it.
    if (!std.mem.eql(u8, cfg.database_path, "memxt.db")) return;
    // A project-local palace already exists here: keep using it.
    if (fileExists(cfg.database_path)) return;

    const home_raw = c.getenv("HOME") orelse return;
    const home = std.mem.span(home_raw);
    const tmp = std.fmt.allocPrint(allocator, "{s}/.memxt/palace.db", .{home}) catch return;
    defer allocator.free(tmp);
    cfg.database_path = allocator.dupeZ(u8, tmp) catch return;
}

/// If nothing (yaml nor MEMXT_WING) picked a wing, scope the default wing to
/// the current project instead of dumping every project on the machine into
/// one shared "default" wing. Prefers the basename of the git repository
/// root (walking up from cwd looking for a `.git` entry); falls back to the
/// basename of cwd; falls back to leaving "default" untouched.
fn resolveDefaultWing(cfg: *Config, allocator: std.mem.Allocator) void {
    if (!std.mem.eql(u8, cfg.default_wing, "default")) return;
    if (deriveProjectWing(allocator)) |derived| {
        cfg.default_wing = derived;
    }
}

/// Walk up from cwd looking for a `.git` entry (dir for a normal repo, file
/// for a worktree/submodule). Returns the sanitized basename of the
/// directory that contains it, or the sanitized basename of cwd if no git
/// root is found. Returns null if cwd can't be determined or the derived
/// name would be empty (caller keeps the "default" fallback).
fn deriveProjectWing(allocator: std.mem.Allocator) ?[:0]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = c.getcwd(&buf, buf.len) orelse return null;
    const cwd = std.mem.span(cwd_ptr);
    if (cwd.len == 0) return null;

    var current: []const u8 = cwd;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const git_path = std.fmt.allocPrintSentinel(allocator, "{s}/.git", .{current}, 0) catch break;
        defer allocator.free(git_path);
        if (fileExists(git_path)) {
            return sanitizeWingName(allocator, std.fs.path.basename(current));
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }

    // No git root found anywhere above cwd; fall back to cwd's basename.
    return sanitizeWingName(allocator, std.fs.path.basename(cwd));
}

/// Trim and validate a candidate wing name, returning a heap-allocated
/// sentinel-terminated copy. Returns null if the trimmed name is empty.
fn sanitizeWingName(allocator: std.mem.Allocator, name: []const u8) ?[:0]const u8 {
    const trimmed = std.mem.trim(u8, name, " \r\t");
    if (trimmed.len == 0) return null;
    return allocator.dupeZ(u8, trimmed) catch null;
}

fn fileExists(path: [:0]const u8) bool {
    return c.access(path.ptr, 0) == 0; // F_OK
}

/// If the configured model isn't where it points, fall back to the curl
/// installer's standard location so an installed binary finds its model with
/// zero config: ~/.memxt/lib/minilm.gguf. (The Homebrew formula sets
/// MEMXT_MODEL explicitly via a wrapper, so it never reaches here.)
fn resolveModelPath(cfg: *Config, allocator: std.mem.Allocator) void {
    if (fileExists(cfg.model_path)) return;

    const home_raw = c.getenv("HOME") orelse return;
    const home = std.mem.span(home_raw);
    const tmp = std.fmt.allocPrint(allocator, "{s}/.memxt/lib/minilm.gguf", .{home}) catch return;
    defer allocator.free(tmp);
    const cand = allocator.dupeZ(u8, tmp) catch return;
    if (fileExists(cand)) {
        if (!std.mem.eql(u8, cfg.model_path, "lib/minilm.gguf")) allocator.free(cfg.model_path);
        cfg.model_path = cand;
    } else {
        allocator.free(cand);
    }
}

fn overrideZ(field: *[:0]const u8, default_lit: []const u8, env_key: [:0]const u8, allocator: std.mem.Allocator) void {
    const raw = c.getenv(env_key.ptr) orelse return;
    const val = std.mem.span(raw);
    if (val.len == 0) return;
    const dup = allocator.dupeZ(u8, val) catch return;
    if (!std.mem.eql(u8, field.*, default_lit)) allocator.free(field.*);
    field.* = dup;
}

const String = []const u8;

fn extractYamlValue(input: []const u8) []const u8 {
    var val = std.mem.trim(u8, input, " \r\t\"");
    if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
        val = val[1 .. val.len - 1];
    }
    return val;
}

// ═══════════════════════════════════════════════════════════════════
// Automated Testing Suite
// ═══════════════════════════════════════════════════════════════════

test "MEMXT_WING env override wins over derived default" {
    const allocator = std.testing.allocator;
    _ = c.setenv("MEMXT_WING", "explicit-wing", 1);
    defer _ = c.unsetenv("MEMXT_WING");

    var cfg = Config{};
    applyEnvOverrides(&cfg, allocator);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("explicit-wing", cfg.default_wing);
}

test "unconfigured database_path anchors to ~/.memxt/palace.db, not a stray cwd file" {
    const allocator = std.testing.allocator;
    _ = c.unsetenv("MEMXT_DB");

    var cfg = Config{};
    applyEnvOverrides(&cfg, allocator);
    defer cfg.deinit(allocator);

    // Regression: the default used to stay the relative literal "memxt.db",
    // so running memxt from any project dir created an empty palace there and
    // reported "0 wings, 0 drawers" — indistinguishable from losing everything.
    // (Guarded: only assert the rewrite when there's no project-local palace in
    // cwd, since an existing ./memxt.db is legitimately preferred.)
    if (!fileExists("memxt.db")) {
        try std.testing.expect(!std.mem.eql(u8, cfg.database_path, "memxt.db"));
        try std.testing.expect(std.mem.endsWith(u8, cfg.database_path, "/.memxt/palace.db"));
        try std.testing.expect(std.fs.path.isAbsolute(cfg.database_path));
    }
}

test "MEMXT_DB env override is never second-guessed" {
    const allocator = std.testing.allocator;
    _ = c.setenv("MEMXT_DB", "/tmp/explicit-palace.db", 1);
    defer _ = c.unsetenv("MEMXT_DB");

    var cfg = Config{};
    applyEnvOverrides(&cfg, allocator);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/explicit-palace.db", cfg.database_path);
}

test "default wing derives from project when nothing is configured" {
    const allocator = std.testing.allocator;
    _ = c.unsetenv("MEMXT_WING");

    var cfg = Config{};
    applyEnvOverrides(&cfg, allocator);
    defer cfg.deinit(allocator);

    // `zig build test` runs with cwd inside this git checkout, so the
    // derived wing should be scoped to the project rather than staying the
    // generic "default" literal shared by every project on the machine.
    try std.testing.expect(!std.mem.eql(u8, cfg.default_wing, "default"));
}
