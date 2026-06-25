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
        // Negative return = buffer too small; we intentionally truncate to MAX_TOKENS.
        if (n < 0) n = MAX_TOKENS;
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

pub fn initGlobal(model_path: [:0]const u8) !void {
    if (global_emb != null) return;
    global_emb = try Embedder.init(model_path);
}

pub fn deinitGlobal() void {
    if (global_emb != null) {
        global_emb.?.deinit();
        global_emb = null;
    }
}

/// True once a model is loaded. Lets callers degrade gracefully (e.g. keyword
/// search) instead of hard-failing when no model is configured.
pub fn isReady() bool {
    return global_emb != null;
}

pub fn embed(text: []const u8, allocator: Allocator) ![]f32 {
    if (global_emb) |*e| {
        return e.embed(text, allocator);
    }
    return error.EmbedderNotInitialized;
}
