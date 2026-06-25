// ═══════════════════════════════════════════════════════════════════
// memxt/miner.zig — Content Mining Engine
//
// Ingests project files and conversation exports into the palace.
// Handles chunking, deduplication, and room auto-detection.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const db = @import("db.zig");
const palace_mod = @import("palace.zig");
const embed = @import("embedder.zig");

const Allocator = std.mem.Allocator;
const Palace = palace_mod.Palace;

pub const MineStats = struct {
    files_processed: u32 = 0,
    drawers_created: u32 = 0,
    files_skipped: u32 = 0,
    bytes_processed: u64 = 0,
    /// Chunks that failed to embed or insert. Non-zero means some content was
    /// NOT remembered — surfaced to the caller rather than swallowed silently.
    errors: u32 = 0,
};

pub const MineOptions = struct {
    wing_name: []const u8 = "default",
    mode: Mode = .files,
    max_chunk_size: usize = 2048,
    chunk_overlap: usize = 256,

    pub const Mode = enum { files, convos };
};

/// Mine a directory of files into the palace
pub fn mineDirectory(
    palace: *Palace,
    dir_path: []const u8,
    options: MineOptions,
    io: std.Io,
    allocator: Allocator,
) !MineStats {
    var stats = MineStats{};

    // Ensure the wing exists
    const wing_id = try palace.createWing(options.wing_name, "", "auto-mined");

    // We'll map the top-level directory to a single room for now,
    // though a real miner might create a room per sub-folder.
    const room_name = std.fs.path.basename(dir_path);
    const room_id = try palace.createRoom(wing_id, room_name, "auto-mined");

    // Open and walk the directory
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Error opening directory '{s}': {}\n", .{ dir_path, err });
        return stats;
    };
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return stats;
    defer walker.deinit();

    var group: std.Io.Group = .init;
    
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;

        if (shouldSkipFile(entry.basename)) {
            stats.files_skipped += 1;
            continue;
        }

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path }) catch continue;
        const entry_path_dupe = allocator.dupe(u8, entry.path) catch {
            allocator.free(full_path);
            continue;
        };

        // Spawn a concurrent task for each file
        group.concurrent(io, processFileConcurrently, .{
            palace, full_path, entry_path_dupe, room_id, options, io, allocator, &stats
        }) catch continue;
    }
    
    // Wait for all concurrent mining tasks to complete
    try group.await(io);

    return stats;
}

fn processFileConcurrently(
    palace: *Palace,
    full_path: []const u8,
    entry_path: []const u8,
    room_id: i64,
    options: MineOptions,
    io: std.Io,
    allocator: Allocator,
    stats: *MineStats,
) std.Io.Cancelable!void {
    defer allocator.free(full_path);
    defer allocator.free(entry_path);

    const dir = std.Io.Dir.cwd();
    const content = readFileContent(dir, io, full_path, allocator) orelse {
        _ = @atomicRmw(u32, &stats.files_skipped, .Add, 1, .monotonic);
        return;
    };
    defer allocator.free(content);

    if (content.len == 0) {
        _ = @atomicRmw(u32, &stats.files_skipped, .Add, 1, .monotonic);
        return;
    }

    _ = @atomicRmw(u64, &stats.bytes_processed, .Add, content.len, .monotonic);

    const chunks = chunkContent(content, options.max_chunk_size, options.chunk_overlap, allocator) catch return;
    defer {
        for (chunks) |chunk| allocator.free(chunk);
        allocator.free(chunks);
    }

    var drawers_added: u32 = 0;
    var errors: u32 = 0;
    for (chunks, 0..) |chunk, i| {
        const embedding = embed.embed(chunk, allocator) catch |err| {
            std.debug.print("warn: embed failed for {s} chunk {d}: {s}\n", .{ entry_path, i, @errorName(err) });
            errors += 1;
            continue;
        };
        defer allocator.free(embedding);

        _ = palace.insertDrawer(room_id, chunk, entry_path, "file", @intCast(i), embedding) catch |err| {
            std.debug.print("warn: store failed for {s} chunk {d}: {s}\n", .{ entry_path, i, @errorName(err) });
            errors += 1;
            continue;
        };

        drawers_added += 1;
    }

    _ = @atomicRmw(u32, &stats.drawers_created, .Add, drawers_added, .monotonic);
    _ = @atomicRmw(u32, &stats.errors, .Add, errors, .monotonic);
    _ = @atomicRmw(u32, &stats.files_processed, .Add, 1, .monotonic);
}

/// Mine a single document file (source code, markdown, notes — anything that
/// isn't a chat export). Chunks, embeds, and inserts it under a room named for
/// the file. This is the path a lone `mine <file>` takes.
pub fn mineFile(
    palace: *Palace,
    file_path: []const u8,
    wing_name: []const u8,
    io: std.Io,
    allocator: Allocator,
) !MineStats {
    var stats = MineStats{};

    const wing_id = try palace.createWing(wing_name, "", "auto-mined");
    const room_name = std.fs.path.basename(file_path);
    const room_id = try palace.createRoom(wing_id, room_name, "auto-mined");

    const dir = std.Io.Dir.cwd();
    const content = readFileContent(dir, io, file_path, allocator) orelse return stats;
    defer allocator.free(content);
    if (content.len == 0) return stats;

    stats.bytes_processed = content.len;

    const chunks = try chunkContent(content, 2048, 256, allocator);
    defer {
        for (chunks) |chunk| allocator.free(chunk);
        allocator.free(chunks);
    }

    for (chunks, 0..) |chunk, i| {
        const embedding = embed.embed(chunk, allocator) catch |err| {
            std.debug.print("warn: embed failed for {s} chunk {d}: {s}\n", .{ file_path, i, @errorName(err) });
            stats.errors += 1;
            continue;
        };
        defer allocator.free(embedding);
        _ = palace.insertDrawer(room_id, chunk, file_path, "file", @intCast(i), embedding) catch |err| {
            std.debug.print("warn: store failed for {s} chunk {d}: {s}\n", .{ file_path, i, @errorName(err) });
            stats.errors += 1;
            continue;
        };
        stats.drawers_created += 1;
    }
    stats.files_processed = 1;
    return stats;
}

/// Store a single in-memory snippet (a decision, quote, or code block) as one
/// drawer. Used by the MCP `store` tool and the auto-save hooks — no file I/O.
pub fn storeMemory(
    palace: *Palace,
    content: []const u8,
    wing_name: []const u8,
    room_name: []const u8,
    source: []const u8,
    allocator: Allocator,
) !i64 {
    const wing_id = try palace.createWing(wing_name, "", "memory");
    const room_id = try palace.createRoom(wing_id, room_name, "");
    const embedding = embed.embed(content, allocator) catch &[_]f32{};
    defer if (embedding.len > 0) allocator.free(embedding);
    return palace.insertDrawer(room_id, content, source, "memory", 0, embedding);
}

/// Mine a conversation file (JSON/JSONL chat export)
pub fn mineConversation(
    palace: *Palace,
    file_path: []const u8,
    wing_name: []const u8,
    io: std.Io,
    allocator: Allocator,
) !MineStats {
    var stats = MineStats{};

    const wing_id = try palace.createWing(wing_name, "", "conversation");
    const room_id = try palace.createRoom(wing_id, "chat", "conversation export");

    const content = blk: {
        const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch return stats;
        defer file.close(io);

        const stat = file.stat(io) catch return stats;
        if (stat.size > 10 * 1024 * 1024) return stats; // Limit to 10MB
        if (stat.size == 0) return stats;

        const buffer = allocator.alloc(u8, @intCast(stat.size)) catch return stats;
        const read_len = file.readPositionalAll(io, buffer, 0) catch {
            allocator.free(buffer);
            return stats;
        };
        break :blk buffer[0..read_len];
    };
    defer allocator.free(content);

    stats.bytes_processed = content.len;

    // Try to parse as JSONL (one message per line)
    var lines = std.mem.splitScalar(u8, content, '\n');
    var message_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer message_buf.deinit(allocator);
    var msg_count: u32 = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Accumulate messages into chunks
        message_buf.appendSlice(allocator, trimmed) catch continue;
        message_buf.append(allocator, '\n') catch continue;
        msg_count += 1;

        // Flush every ~10 messages as a chunk
        if (msg_count >= 10) {
            const chunk = message_buf.toOwnedSlice(allocator) catch continue;
            defer allocator.free(chunk);

            const embedding = embed.embed(chunk, allocator) catch continue;
            defer allocator.free(embedding);

            _ = palace.insertDrawer(room_id, chunk, file_path, "conversation", @intCast(stats.drawers_created), embedding) catch continue;
            stats.drawers_created += 1;
            msg_count = 0;
        }
    }

    // Flush remaining
    if (message_buf.items.len > 0) {
        const chunk = message_buf.toOwnedSlice(allocator) catch return stats;
        defer allocator.free(chunk);

        const embedding = embed.embed(chunk, allocator) catch return stats;
        defer allocator.free(embedding);

        _ = palace.insertDrawer(room_id, chunk, file_path, "conversation", @intCast(stats.drawers_created), embedding) catch {};
        stats.drawers_created += 1;
    }

    stats.files_processed = 1;
    return stats;
}

// ── Chunking ──

fn chunkContent(content: []const u8, max_size: usize, overlap: usize, allocator: Allocator) ![][]const u8 {
    if (content.len <= max_size) {
        const chunks = try allocator.alloc([]const u8, 1);
        chunks[0] = try allocator.dupe(u8, content);
        return chunks;
    }

    var chunk_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (chunk_list.items) |c| allocator.free(c);
        chunk_list.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < content.len) {
        const end = @min(pos + max_size, content.len);

        // Try to break at a paragraph or sentence boundary
        var break_pos = end;
        if (end < content.len) {
            // Look for paragraph break
            if (std.mem.lastIndexOf(u8, content[pos..end], "\n\n")) |idx| {
                if (idx > max_size / 4) break_pos = pos + idx + 2;
            } else if (std.mem.lastIndexOfScalar(u8, content[pos..end], '\n')) |idx| {
                if (idx > max_size / 4) break_pos = pos + idx + 1;
            }
        }

        try chunk_list.append(allocator, try allocator.dupe(u8, content[pos..break_pos]));

        if (break_pos >= content.len) break;
        pos = if (break_pos > overlap) break_pos - overlap else break_pos;
    }

    return chunk_list.toOwnedSlice(allocator);
}

// ── File Filtering ──

fn shouldSkipFile(basename: []const u8) bool {
    // Skip hidden files
    if (basename.len > 0 and basename[0] == '.') return true;

    // Skip by extension
    const skip_exts = [_][]const u8{
        ".png",  ".jpg",  ".jpeg", ".gif",  ".svg",  ".ico",  ".webp",
        ".mp3",  ".mp4",  ".wav",  ".avi",  ".mkv",  ".mov",
        ".zip",  ".tar",  ".gz",   ".bz2",  ".xz",   ".7z",
        ".exe",  ".dll",  ".so",   ".dylib", ".o",   ".a",
        ".bin",  ".dat",  ".db",   ".sqlite",
        ".wasm", ".pyc",  ".class",
        ".lock", ".sum",
    };

    const ext = std.fs.path.extension(basename);
    for (skip_exts) |skip| {
        if (std.ascii.eqlIgnoreCase(ext, skip)) return true;
    }

    // Skip our own database + its SQLite sidecars (WAL/SHM) so the palace never
    // mines itself.
    if (std.mem.indexOf(u8, basename, ".db-wal") != null) return true;
    if (std.mem.indexOf(u8, basename, ".db-shm") != null) return true;
    if (std.mem.indexOf(u8, basename, "memxt.db") != null) return true;
    if (std.mem.indexOf(u8, basename, "mempalace.db") != null) return true;

    // Skip known directories in filenames
    if (std.mem.indexOf(u8, basename, "node_modules") != null) return true;
    if (std.mem.indexOf(u8, basename, "__pycache__") != null) return true;

    return false;
}

fn readFileContent(dir: std.Io.Dir, io: std.Io, path: []const u8, allocator: Allocator) ?[]u8 {
    const file = dir.openFile(io, path, .{}) catch return null;
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    if (stat.size > 10 * 1024 * 1024) return null; // Limit to 10MB
    if (stat.size == 0) return null;

    const buffer = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const read_len = file.readPositionalAll(io, buffer, 0) catch {
        allocator.free(buffer);
        return null;
    };

    if (read_len < stat.size) {
        // Optional shrinking, but let's just return what we read as slice
        return buffer[0..read_len];
    }
    return buffer;
}
