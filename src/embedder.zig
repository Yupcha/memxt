// ═══════════════════════════════════════════════════════════════════
// memxt/embedder.zig — Local Vector Embeddings (llama.cpp)
//
// Runs a GGUF sentence-embedding model (default: MiniLM-L6-v2, 384-dim)
// fully on-device via statically-linked llama.cpp. Encoder models use
// llama_encode + mean pooling; output vectors are L2-normalized so a
// vec0 L2 distance is monotonic with cosine similarity.
//
// A single llama_context is shared process-wide and guarded by a mutex,
// so the concurrent miner can call embed() from multiple tasks safely.
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("llama.h");
});

/// libc bits used only to locate the installed model in tests.
const libc = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

// MiniLM-L6-v2 embedding width. The vec_drawers virtual table is declared
// float[384], so the active model MUST match this. Validated in init().
pub const EMBEDDING_DIM = 384;

// Hard cap on tokens per chunk. MiniLM's positional limit is 512; we keep a
// little headroom for special tokens and simply truncate longer inputs.
const MAX_TOKENS = 512;

pub const Embedder = struct {
    model: *c.llama_model,
    ctx: *c.llama_context,
    vocab: *const c.llama_vocab,
    n_embd: i32,
    is_encoder: bool,
    // Lightweight spinlock guarding the shared llama_context. Works under any
    // IO threading model (unlike std.Io.Mutex it needs no `io` handle), and
    // contention is brief since embed() is short and CPU-bound.
    lock_flag: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *Embedder) void {
        while (self.lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn release(self: *Embedder) void {
        self.lock_flag.store(false, .release);
    }

    pub fn init(model_path: [:0]const u8) !Embedder {
        // Silence llama.cpp's stderr chatter so it can never corrupt the JSON
        // we emit on stdout for the MCP server and Claude Code hooks.
        c.llama_log_set(quietLog, null);
        c.llama_backend_init();

        var mparams = c.llama_model_default_params();
        mparams.n_gpu_layers = 99; // tiny model — offload fully where available (Metal/CUDA)
        mparams.use_mmap = true;
        const model = c.llama_model_load_from_file(model_path.ptr, mparams) orelse return error.ModelLoadFailed;
        errdefer c.llama_model_free(model);

        const vocab = c.llama_model_get_vocab(model) orelse return error.VocabLoadFailed;
        const n_embd = c.llama_model_n_embd(model);
        if (n_embd != EMBEDDING_DIM) {
            // Dimension mismatch would silently break vec0 inserts/search.
            std.debug.print(
                "memxt: model embedding dim {d} != expected {d}. Use a {d}-dim model.\n",
                .{ n_embd, EMBEDDING_DIM, EMBEDDING_DIM },
            );
            return error.EmbeddingDimMismatch;
        }

        var cparams = c.llama_context_default_params();
        cparams.n_ctx = MAX_TOKENS;
        cparams.n_batch = MAX_TOKENS;
        cparams.n_ubatch = MAX_TOKENS;
        cparams.embeddings = true;
        cparams.pooling_type = c.LLAMA_POOLING_TYPE_MEAN;
        const ctx = c.llama_init_from_model(model, cparams) orelse return error.ContextInitFailed;

        return .{
            .model = model,
            .ctx = ctx,
            .vocab = vocab,
            .n_embd = n_embd,
            .is_encoder = c.llama_model_has_encoder(model),
        };
    }

    pub fn deinit(self: *Embedder) void {
        c.llama_free(self.ctx);
        c.llama_model_free(self.model);
        c.llama_backend_free();
    }

    /// Generate an L2-normalized embedding for `text`. Caller owns the result.
    /// Thread-safe: the underlying llama_context is serialized via a mutex.
    pub fn embed(self: *Embedder, text: []const u8, allocator: Allocator) ![]f32 {
        self.acquire();
        defer self.release();

        // Each embed() is an independent sentence, but the context's KV cache is
        // shared across calls under sequence 0. Without clearing it, a shorter
        // input embedded after a longer one leaves stale keys/values at the
        // trailing positions; this non-causal model attends to every cached
        // position in the sequence, silently contaminating the embedding. Reset
        // to a clean slate so every embedding depends only on its own tokens.
        c.llama_memory_clear(c.llama_get_memory(self.ctx), true);

        // ── Tokenize ──
        const tokens = try allocator.alloc(c.llama_token, MAX_TOKENS);
        defer allocator.free(tokens);

        var n = c.llama_tokenize(
            self.vocab,
            text.ptr,
            @intCast(text.len),
            tokens.ptr,
            @intCast(MAX_TOKENS),
            true, // add_special (BOS/CLS as configured by the model)
            false, // parse_special
        );
        if (n < 0) {
            // The text is longer than MAX_TOKENS. llama_tokenize signals this by
            // returning -(full token count) and writes NOTHING into `tokens` —
            // so we must not just clamp n and feed the buffer, or we'd embed
            // uninitialized garbage token ids (garbage in ReleaseFast, 0xAA in
            // Debug → llama_decode fails). Re-tokenize into a big-enough buffer,
            // then keep the first MAX_TOKENS valid tokens (positions stay ≤511).
            const needed: usize = @intCast(-n);
            const full = try allocator.alloc(c.llama_token, needed);
            defer allocator.free(full);
            const m = c.llama_tokenize(self.vocab, text.ptr, @intCast(text.len), full.ptr, @intCast(needed), true, false);
            if (m <= 0) return error.EmptyInput;
            const keep = @min(MAX_TOKENS, @as(usize, @intCast(m)));
            @memcpy(tokens[0..keep], full[0..keep]);
            n = @intCast(keep);
        }
        if (n == 0) return error.EmptyInput;
        const n_tok: usize = @intCast(n);

        // ── Build a single-sequence batch ──
        var batch = c.llama_batch_init(@intCast(n_tok), 0, 1);
        defer c.llama_batch_free(batch);
        batch.n_tokens = @intCast(n_tok);

        var i: usize = 0;
        while (i < n_tok) : (i += 1) {
            batch.token[i] = tokens[i];
            batch.pos[i] = @intCast(i);
            batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = 0;
            batch.logits[i] = 1; // request output for every token so pooling has data
        }

        // ── Run the model ──
        const rc = if (self.is_encoder)
            c.llama_encode(self.ctx, batch)
        else
            c.llama_decode(self.ctx, batch);
        if (rc != 0) return error.EncodeFailed;

        // ── Read the pooled (mean) embedding for sequence 0 ──
        const emb_ptr = c.llama_get_embeddings_seq(self.ctx, 0) orelse return error.NoEmbedding;
        const dim: usize = @intCast(self.n_embd);

        const out = try allocator.alloc(f32, dim);
        errdefer allocator.free(out);

        var sum_sq: f32 = 0;
        i = 0;
        while (i < dim) : (i += 1) {
            const v = emb_ptr[i];
            out[i] = v;
            sum_sq += v * v;
        }
        if (sum_sq > 0) {
            const inv_norm = 1.0 / @sqrt(sum_sq);
            for (out) |*v| v.* *= inv_norm;
        }
        return out;
    }
};

fn quietLog(level: c.ggml_log_level, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = level;
    _ = text;
    _ = user_data;
}

// ── Process-global embedder ──

var global_emb: ?Embedder = null;
/// Path recorded by `setModelPath` so `embed` can lazy-load on first real use.
/// Points at config/env memory — not freed here.
var pending_model_path: ?[:0]const u8 = null;

/// `global_emb` is a by-value `?Embedder`, so *assigning* it rewrites the
/// struct in place — including `lock_flag`, the very spinlock `embed()` uses to
/// serialize the llama_context. Lazy-init therefore MUST be serialized itself:
/// the miner calls `embed()` from one concurrent task per file, and an
/// unguarded `if (global_emb == null) global_emb = init()` let every task see
/// null, build its own Embedder, and overwrite the global underneath the
/// others. In-flight calls had their `ctx` swapped mid-encode and their lock
/// reset, which surfaced as a storm of EncodeFailed/NoEmbedding and silently
/// dropped ~90% of chunks when mining a directory (single-file mining has one
/// task, so it never raced and always looked fine).
///
/// `emb_ready` is the atomic publication flag — `global_emb` itself is a wide
/// struct and can't be loaded atomically. Once published, `global_emb` is never
/// reassigned until `deinitGlobal`, so `&global_emb.?` stays stable.
var emb_ready: std.atomic.Value(bool) = .init(false);
var init_lock: std.atomic.Value(bool) = .init(false);

/// Initialize the process-global embedder exactly once. Safe to call from many
/// threads concurrently; losers of the race wait and observe the winner's.
fn initGlobalOnce(model_path: [:0]const u8) !void {
    if (emb_ready.load(.acquire)) return;

    while (init_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    defer init_lock.store(false, .release);

    // Double-check under the lock: another thread may have published while we
    // were spinning.
    if (emb_ready.load(.acquire)) return;

    global_emb = try Embedder.init(model_path);
    emb_ready.store(true, .release);
}

/// Remember where the model lives without loading it. Mine can then skip the
/// ~0.5s Metal init entirely when every chunk is already stored (incremental).
pub fn setModelPath(model_path: [:0]const u8) void {
    pending_model_path = model_path;
}

pub fn initGlobal(model_path: [:0]const u8) !void {
    pending_model_path = model_path;
    try initGlobalOnce(model_path);
}

pub fn deinitGlobal() void {
    if (global_emb != null) {
        global_emb.?.deinit();
        global_emb = null;
    }
    emb_ready.store(false, .release);
    pending_model_path = null;
}

/// True once a model is loaded. Lets callers degrade gracefully (e.g. keyword
/// search) instead of hard-failing when no model is configured.
pub fn isReady() bool {
    return emb_ready.load(.acquire);
}

fn ensureReady() !void {
    if (emb_ready.load(.acquire)) return;
    const path = pending_model_path orelse return error.EmbedderNotInitialized;
    try initGlobalOnce(path);
}

pub fn embed(text: []const u8, allocator: Allocator) ![]f32 {
    try ensureReady();
    if (global_emb) |*e| {
        return e.embed(text, allocator);
    }
    return error.EmbedderNotInitialized;
}

// ═══════════════════════════════════════════════════════════════════
// Regression tests
// ═══════════════════════════════════════════════════════════════════

test "concurrent embed() does not race the lazy global init" {
    const allocator = std.testing.allocator;

    // Needs the real model. Skip where it isn't installed (clean CI checkout).
    const home_raw = libc.getenv("HOME") orelse return error.SkipZigTest;
    const home = std.mem.span(home_raw);
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/.memxt/lib/minilm.gguf", .{home}, 0) catch return error.SkipZigTest;
    defer allocator.free(path);
    if (libc.access(path.ptr, 0) != 0) return error.SkipZigTest;

    deinitGlobal();
    setModelPath(path);

    // The miner spawns one concurrent task per file, all landing in embed().
    // Pre-fix, each saw `global_emb == null`, built its own Embedder and
    // overwrote the global — swapping the llama_context (and resetting
    // `lock_flag`, the spinlock guarding it) underneath in-flight calls. Most
    // chunks then died with EncodeFailed/NoEmbedding and were silently dropped:
    // mining src/ui (22 files) stored 4 drawers instead of 504, and still
    // exited 0. Hammer the cold-start path from many threads at once; every
    // call must succeed.
    const N = 8;
    const Worker = struct {
        fn run(ok: *std.atomic.Value(u32), bad: *std.atomic.Value(u32), idx: usize) void {
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "regression sentence number {d}", .{idx}) catch return;
            const a = std.testing.allocator;
            if (embed(text, a)) |vec| {
                a.free(vec);
                _ = ok.fetchAdd(1, .monotonic);
            } else |_| {
                _ = bad.fetchAdd(1, .monotonic);
            }
        }
    };

    var ok: std.atomic.Value(u32) = .init(0);
    var bad: std.atomic.Value(u32) = .init(0);
    var threads: [N]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = std.Thread.spawn(.{}, Worker.run, .{ &ok, &bad, i }) catch return error.SkipZigTest;
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u32, 0), bad.load(.monotonic));
    try std.testing.expectEqual(@as(u32, N), ok.load(.monotonic));

    deinitGlobal();
}
