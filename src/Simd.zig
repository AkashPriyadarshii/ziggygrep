const std = @import("std");

// Packed-pair SIMD substring confirm. Port of the memchr packedpair idea
// via aarol's Zig writeup: instead of confirming a candidate line with a
// scalar Boyer-Moore-Horspool (`std.mem.indexOf`), compare two needle
// bytes across 32-byte blocks with SIMD, AND the masks, and verify only
// the surviving candidates with `mem.eql`.
//
// Which two bytes: the two rarest in the needle by a static frequency
// table (memchr's packedpair does the same). Rarest pair minimizes
// candidates, which minimizes the expensive `eql` verifications and the
// branch misses they cause.
//
// Width: 64 lanes (2x AVX2 registers on x86_64-v3). Halves loop trips
// on the wide pair-byte scan vs 32-wide. Tail scalar covers the rest.
//
// ponytail: no runtime CPU detection. Release builds target x86_64-v3
// in build.zig; debug builds use this same code and the compiler splits
// vectors for baseline. One code path, zero dispatch.

const Width: usize = 64;
const Block = @Vector(Width, u8);

pub const Pair = struct {
    off0: usize,
    off1: usize,
    b0: Block,
    b1: Block,
};

/// Pick the two rarest byte offsets in the needle. Requires len >= 2.
pub fn pickPair(needle: []const u8) Pair {
    std.debug.assert(needle.len >= 2);
    var best0: usize = 0;
    var best1: usize = 1;
    var rank0: u8 = rank(needle[0]);
    var rank1: u8 = rank(needle[1]);
    if (rank1 < rank0) {
        std.mem.swap(usize, &best0, &best1);
        std.mem.swap(u8, &rank0, &rank1);
    }
    for (needle[2..], 2..) |b, i| {
        const r = rank(b);
        if (r < rank0) {
            best1 = best0;
            rank1 = rank0;
            best0 = i;
            rank0 = r;
        } else if (r < rank1) {
            best1 = i;
            rank1 = r;
        }
    }
    return .{
        .off0 = best0,
        .off1 = best1,
        .b0 = @splat(needle[best0]),
        .b1 = @splat(needle[best1]),
    };
}

// Static byte rarity: lower is rarer. memchr's packedpair uses a measured
// frequency table; this is a compact approximation over the same idea:
// control bytes and symbols are rare, 'e' and space are everywhere.
fn rank(b: u8) u8 {
    return switch (b) {
        0...8, 11, 12, 14...31, 127...255 => 0,
        'z', 'q', 'x', 'j', 'k', 'v', 'w' => 1,
        'Z', 'Q', 'X', 'J', 'K', 'V', 'W' => 1,
        'b', 'g', 'p', 'y', 'f', 'u', 'c' => 2,
        'B', 'G', 'P', 'Y', 'F', 'U', 'C' => 2,
        'm', 'd', 'h', 'l', 's', 'r' => 3,
        'M', 'D', 'H', 'L', 'S', 'R' => 3,
        'n', 'i', 'o', 'a', 't' => 4,
        'N', 'I', 'O', 'A', 'T' => 4,
        '0'...'9' => 5,
        ' ', 'e', 'E' => 6,
        else => 3,
    };
}

/// True if needle occurs in line. Lines here average ~85 bytes, so one
/// 64-wide SIMD block rarely fills: scalar mem.indexOf (which is BMH
/// for len>4, linear for short) beats the pair-scan setup on every
/// length. The packed-pair path stays for plug-in long-line corpora.
pub inline fn contains(line: []const u8, needle: []const u8, pair: ?Pair) bool {
    _ = pair;
    return std.mem.indexOf(u8, line, needle) != null;
}

/// Packed-pair entry kept for long-line corpora and the fuzz test.
pub inline fn containsPair(line: []const u8, needle: []const u8, pair: ?Pair) bool {
    if (needle.len < 2 or line.len < needle.len) {
        if (line.len < needle.len) return false;
        return std.mem.indexOf(u8, line, needle) != null;
    }
    // Short needles (<=4): linear scan beats both BMH and SIMD setup.
    // NOTE: kept for the fuzz test; production contains() above routes
    // everything through mem.indexOf until long-line evidence returns.
    if (needle.len <= 4) return std.mem.indexOf(u8, line, needle) != null;
    const p = pair orelse pickPair(needle);
    return containsSimd(line, needle, p);
}

fn containsSimd(line: []const u8, needle: []const u8, p: Pair) bool {
    const k = needle.len;
    const n = line.len;
    // Need i + off + Width <= n for both offsets, plus room for the full
    // needle at a candidate: i + k <= n.
    const o_max = @max(p.off0, p.off1);
    var i: usize = 0;
    while (i + o_max + Width <= n and i + k <= n) : (i += Width) {
        const blk0: Block = line[i + p.off0 ..][0..Width].*;
        const blk1: Block = line[i + p.off1 ..][0..Width].*;
        const cmp = (p.b0 == blk0) & (p.b1 == blk1);
        // 64 lanes: two shuffles with comptime masks pull the halves.
        const lo: @Vector(32, bool) = @shuffle(bool, cmp, undefined, blk: {
            var m: [32]i32 = undefined;
            for (&m, 0..) |*v, j| v.* = j;
            break :blk m;
        });
        const hi: @Vector(32, bool) = @shuffle(bool, cmp, undefined, blk: {
            var m: [32]i32 = undefined;
            for (&m, 0..) |*v, j| v.* = 32 + j;
            break :blk m;
        });
        const m_lo: u32 = @bitCast(lo);
        const m_hi: u32 = @bitCast(hi);
        var m: u64 = (@as(u64, m_hi) << 32) | m_lo;
        while (m != 0) {
            const bit: usize = @ctz(m);
            m &= m - 1;
            const start = i + bit;
            if (start + k > n) continue;
            if (eqlExcept(line[start .. start + k], needle, p.off0, p.off1)) return true;
        }
    }
    // Tail: scalar.
    if (i + k <= n) {
        if (std.mem.indexOfPos(u8, line, i, needle) != null) return true;
    }
    return false;
}

fn eqlExcept(a: []const u8, b: []const u8, skip0: usize, skip1: usize) bool {
    for (a, b, 0..) |x, y, idx| {
        if (idx == skip0 or idx == skip1) continue;
        if (x != y) return false;
    }
    return true;
}

test "simd: basic contains" {
    const t = std.testing;
    const p = pickPair("HashMap");
    try t.expect(contains("has HashMap here", "HashMap", p));
    try t.expect(!contains("has hashmap here", "HashMap", p));
    try t.expect(!contains("short", "HashMap", p));
}

test "simd: pair picks rare bytes" {
    const t = std.testing;
    // 'z' (rank 1) and 'q' (rank 1) beat 'e' (rank 6).
    const p = pickPair("eezqee");
    try t.expect(p.off0 == 2 or p.off0 == 3);
    try t.expect(p.off1 == 2 or p.off1 == 3);
    try t.expect(p.off0 != p.off1);
}

test "simd: matches scalar on random lines" {
    const t = std.testing;
    var rng = std.Random.DefaultPrng.init(42);
    const needles = [_][]const u8{ "a", "ab", "HashMap", "foo bar", "x", "zzz", "pub fn" };
    var li: usize = 0;
    while (li < 300) : (li += 1) {
        var line: [128]u8 = undefined;
        for (&line) |*b| b.* = rng.random().intRangeAtMost(u8, 32, 122);
        for (needles) |nd| {
            const want = std.mem.indexOf(u8, &line, nd) != null;
            const got = containsPair(&line, nd, if (nd.len >= 2) pickPair(nd) else null);
            try t.expectEqual(want, got);
        }
    }
}

test "simd: long needle past one block" {
    const t = std.testing;
    const nd = "this needle is longer than thirty-two bytes wide yes";    var line: [128]u8 = undefined;
    @memset(&line, 'a');
    @memcpy(line[40 .. 40 + nd.len], nd);
    try t.expect(containsPair(&line, nd, pickPair(nd)));
    try t.expect(!containsPair(&line, "this needle is longer than thirty-two bytes wide no!", pickPair("this needle is longer than thirty-two bytes wide no!")));
}
