// ═══════════════════════════════════════════════════════════════════
// memxt/quant.zig — TurboQuant-inspired online vector quantization
//
// Data-oblivious (no training on the palace):
//   1. Fixed Rademacher signs + Walsh–Hadamard (random-ish rotation)
//   2. Per-coordinate Lloyd–Max style scalar quantizer for N(0, σ)
//   3. Optional 1-bit residual signs (QJL-lite) for better IP recovery
//
// Target: MiniLM 384-d L2-normalized embeddings.
// Storage @ 4-bit: 512 coords × 0.5 B = 256 B codes (+ 64 B residual) ≈ 6× smaller
// than f32 (1536 B), with online encode (no PQ train).
//
// Ref: Zandieh et al., TurboQuant (arXiv:2504.19874)
// ═══════════════════════════════════════════════════════════════════

const std = @import("std");
const embedder = @import("embedder.zig");

pub const DIM: usize = embedder.EMBEDDING_DIM; // 384
/// Pad to power-of-two for FWHT (TurboQuant-style random rotation proxy).
pub const ROT_DIM: usize = 512;
pub const DEFAULT_NBITS: u8 = 4;

/// Packed quantized vector ready for SQLite BLOB storage.
pub const QuantVec = struct {
    nbits: u8,
    /// Packed codes: ceil(ROT_DIM * nbits / 8) bytes
    codes: []u8,
    /// 1-bit residual signs after MSE quant (ROT_DIM bits → 64 bytes). Improves IP.
    residual_signs: []u8,
    /// L2 norm of residual (for QJL-lite rescaling); 0 if unused.
    residual_norm: f32,

    pub fn deinit(self: *QuantVec, allocator: std.mem.Allocator) void {
        allocator.free(self.codes);
        allocator.free(self.residual_signs);
    }

    pub fn codeBytes(nbits: u8) usize {
        return (ROT_DIM * @as(usize, nbits) + 7) / 8;
    }
};

// ── Fixed codebooks: reconstruction levels for N(0,1), scaled by 1/√ROT_DIM later ──
// 4-bit (16 levels) — approximate Lloyd-Max for standard normal (symmetric).
const CODEBOOK_4: [16]f32 = .{
    -2.401, -1.844, -1.437, -1.099,
    -0.799, -0.522, -0.258, 0.0,
    0.258,  0.522,  0.799,  1.099,
    1.437,  1.844,  2.401,  2.900,
};

// 8-bit: uniform-ish coverage of [-3,3] for residual quality / future use.
fn codebook8(level: u8) f32 {
    // Map 0..255 → approx N(0,1) via inverse-ish linear on [-3.1, 3.1]
    const t = (@as(f32, @floatFromInt(level)) + 0.5) / 256.0;
    return (t * 2.0 - 1.0) * 3.1;
}

/// Deterministic Rademacher from seed+index (data-oblivious "random" rotation).
fn rademacher(i: usize) f32 {
    // xorshift mix
    var x: u32 = @truncate(i *% 0x9E3779B9 +% 0xD1B54A32);
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return if ((x & 1) == 0) 1.0 else -1.0;
}

fn fwht(a: []f32) void {
    var h: usize = 1;
    while (h < a.len) : (h *= 2) {
        var i: usize = 0;
        while (i < a.len) : (i += h * 2) {
            var j: usize = i;
            while (j < i + h) : (j += 1) {
                const x = a[j];
                const y = a[j + h];
                a[j] = x + y;
                a[j + h] = x - y;
            }
        }
    }
}

fn invSqrtRot() f32 {
    return 1.0 / @sqrt(@as(f32, @floatFromInt(ROT_DIM)));
}

/// Apply fixed random-ish rotation (signs + FWHT + scale). In/out length ROT_DIM.
fn rotateInPlace(buf: *[ROT_DIM]f32) void {
    for (0..ROT_DIM) |i| buf[i] *= rademacher(i);
    fwht(buf);
    const s = invSqrtRot();
    for (buf) |*v| v.* *= s;
}

fn unrotateInPlace(buf: *[ROT_DIM]f32) void {
    // FWHT is involution up to factor n; we used 1/√n each way → apply same again.
    const s = invSqrtRot();
    for (buf) |*v| v.* *= s;
    fwht(buf);
    // undo the second scale from fwht expansion: after fwht without scale, values * n
    // Our fwht doesn't scale; rotate did scale by 1/√n before and we scale 1/√n before
    // inverse fwht. After inverse fwht: need * 1/√n again? 
    // rotate: x' = (1/√n) H S x
    // H H = n I for unnormalized FWHT, so H^{-1} = H / n
    // unrotate: S H (1/√n) y with y = (1/√n) H S x → S H (1/n) H S x = S (I) S x = x
    // So: scale 1/√n, H, scale 1/√n, S — wait:
    // S * (1/√n) * H * (1/√n) * H * S x = S * (1/n) * (n I) * S x = S S x = x. Yes.
    for (buf) |*v| v.* *= s;
    for (0..ROT_DIM) |i| buf[i] *= rademacher(i);
}

fn nearestCode4(x: f32) u4 {
    // Compare to CODEBOOK_4 levels (already for unit-ish post-rotation scale).
    // Post-rotation coords have std ~ 1/√d for unit vectors ≈ 0.044 for d=512.
    // CODEBOOK is for N(0,1); scale input up.
    const z = x * @sqrt(@as(f32, @floatFromInt(ROT_DIM)));
    var best: u4 = 0;
    var best_d: f32 = std.math.floatMax(f32);
    for (CODEBOOK_4, 0..) |c, i| {
        const d = (z - c) * (z - c);
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

fn reconstruct4(code: u4) f32 {
    const z = CODEBOOK_4[@as(usize, code)];
    return z * invSqrtRot(); // back to post-rotation scale
}

fn nearestCode8(x: f32) u8 {
    const z = x * @sqrt(@as(f32, @floatFromInt(ROT_DIM)));
    // clamp to [-3.1, 3.1] → 0..255
    const t = (z / 3.1 + 1.0) * 0.5;
    const clamped = @min(1.0, @max(0.0, t));
    const level: i32 = @intFromFloat(clamped * 255.0);
    return @intCast(std.math.clamp(level, 0, 255));
}

fn reconstruct8(code: u8) f32 {
    return codebook8(code) * invSqrtRot();
}

fn packNibbles(codes: []const u4, out: []u8) void {
    @memset(out, 0);
    for (codes, 0..) |c, i| {
        const byte_i = i / 2;
        if (i % 2 == 0) {
            out[byte_i] = @as(u8, c);
        } else {
            out[byte_i] |= @as(u8, c) << 4;
        }
    }
}

fn unpackNibbles(in: []const u8, codes: []u4) void {
    for (codes, 0..) |*c, i| {
        const b = in[i / 2];
        c.* = if (i % 2 == 0) @truncate(b & 0x0f) else @truncate((b >> 4) & 0x0f);
    }
}

/// Quantize an L2-normalized (or any) embedding. Caller owns result.
pub fn quantize(embedding: []const f32, nbits: u8, allocator: std.mem.Allocator) !QuantVec {
    if (embedding.len != DIM) return error.DimMismatch;
    if (nbits != 4 and nbits != 8) return error.UnsupportedBits;

    var work: [ROT_DIM]f32 = .{0} ** ROT_DIM;
    @memcpy(work[0..DIM], embedding[0..DIM]);
    rotateInPlace(&work);

    var mse_recon: [ROT_DIM]f32 = undefined;
    const code_bytes = QuantVec.codeBytes(nbits);
    const codes = try allocator.alloc(u8, code_bytes);
    errdefer allocator.free(codes);

    if (nbits == 4) {
        var nib: [ROT_DIM]u4 = undefined;
        for (0..ROT_DIM) |i| {
            nib[i] = nearestCode4(work[i]);
            mse_recon[i] = reconstruct4(nib[i]);
        }
        packNibbles(&nib, codes);
    } else {
        for (0..ROT_DIM) |i| {
            const c = nearestCode8(work[i]);
            codes[i] = c;
            mse_recon[i] = reconstruct8(c);
        }
    }

    // Residual for QJL-lite (1-bit signs)
    var residual_norm_sq: f32 = 0;
    var signs: [ROT_DIM]u8 = undefined; // store as 0/1 then pack
    for (0..ROT_DIM) |i| {
        const r = work[i] - mse_recon[i];
        residual_norm_sq += r * r;
        signs[i] = if (r >= 0) 1 else 0;
    }
    const residual_norm = @sqrt(residual_norm_sq);
    const sign_bytes = try allocator.alloc(u8, (ROT_DIM + 7) / 8);
    @memset(sign_bytes, 0);
    for (0..ROT_DIM) |i| {
        if (signs[i] != 0) {
            sign_bytes[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        }
    }

    return .{
        .nbits = nbits,
        .codes = codes,
        .residual_signs = sign_bytes,
        .residual_norm = residual_norm,
    };
}

/// Dequantize to DIM-dimensional vector (approx). L2-renormalized.
pub fn dequantize(qv: QuantVec, out: *[DIM]f32) void {
    var work: [ROT_DIM]f32 = undefined;

    if (qv.nbits == 4) {
        var nib: [ROT_DIM]u4 = undefined;
        unpackNibbles(qv.codes, &nib);
        for (0..ROT_DIM) |i| work[i] = reconstruct4(nib[i]);
    } else {
        for (0..ROT_DIM) |i| work[i] = reconstruct8(qv.codes[i]);
    }

    // Add residual correction (QJL-lite): ± residual_norm/√ROT_DIM * sign
    if (qv.residual_norm > 1e-8 and qv.residual_signs.len > 0) {
        const step = qv.residual_norm * invSqrtRot();
        for (0..ROT_DIM) |i| {
            const bit: u8 = (qv.residual_signs[i / 8] >> @intCast(i % 8)) & 1;
            const s: f32 = if (bit == 1) 1.0 else -1.0;
            work[i] += s * step;
        }
    }

    unrotateInPlace(&work);

    @memcpy(out, work[0..DIM]);
    // L2 renorm
    var sum_sq: f32 = 0;
    for (out) |v| sum_sq += v * v;
    if (sum_sq > 1e-12) {
        const inv = 1.0 / @sqrt(sum_sq);
        for (out) |*v| v.* *= inv;
    }
}

/// Squared L2 distance between query and dequantized vector (lower = better).
pub fn distanceSq(query: []const f32, qv: QuantVec) f32 {
    var recon: [DIM]f32 = undefined;
    dequantize(qv, &recon);
    var d: f32 = 0;
    for (query, recon) |q, r| {
        const e = q - r;
        d += e * e;
    }
    return d;
}

/// Cosine similarity ≈ IP for L2-normalized vectors (higher = better).
pub fn cosine(query: []const f32, qv: QuantVec) f32 {
    var recon: [DIM]f32 = undefined;
    dequantize(qv, &recon);
    var dot: f32 = 0;
    for (query, recon) |q, r| dot += q * r;
    return dot;
}

// ── Unit tests ──

test "quant roundtrip preserves neighborhood" {
    const allocator = std.testing.allocator;
    var v: [DIM]f32 = undefined;
    // Pseudo unit vector
    for (0..DIM) |i| v[i] = @sin(@as(f32, @floatFromInt(i)) * 0.07);
    var sum_sq: f32 = 0;
    for (v) |x| sum_sq += x * x;
    const inv = 1.0 / @sqrt(sum_sq);
    for (&v) |*x| x.* *= inv;

    var qv = try quantize(&v, 4, allocator);
    defer qv.deinit(allocator);

    var recon: [DIM]f32 = undefined;
    dequantize(qv, &recon);
    var d: f32 = 0;
    for (v, recon) |a, b| {
        const e = a - b;
        d += e * e;
    }
    // 4-bit should keep reasonable fidelity (not perfect)
    try std.testing.expect(d < 0.85);
    try std.testing.expect(cosine(&v, qv) > 0.55);
}
