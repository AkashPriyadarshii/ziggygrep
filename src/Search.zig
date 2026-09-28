const std = @import("std");
const Simd = @import("Simd.zig");

// Literal line scan. Whole-chunk search: one indexOfPos over the buffer,
// bound lines only around hits, jump past the line. The old per-line
// first-byte prefilter restarted search work every 85 bytes and died on
// short patterns (he/in); this matches the rg candidate-search shape.

pub const Span = struct {
    lineno: u64,
    start: usize, // byte offset of line start in buffer
    end: usize, // byte offset of line end (excludes \n, excludes \r)
};

/// Scan buffer for lines containing needle. Returns match spans in order.
/// Caller frees. Empty needle matches nothing.
pub fn search(allocator: std.mem.Allocator, content: []const u8, needle: []const u8) ![]Span {
    const pair: ?Simd.Pair = if (needle.len >= 2) Simd.pickPair(needle) else null;
    return searchWith(allocator, content, needle, pair);
}

/// Same as search but reuses a precomputed pair. Workers compute the pair
/// once per run instead of once per chunk.
/// Emit matches directly into a caller-provided sink instead of building
/// a spans array. The sink gets (lineno, line) per match line in order.
/// Returns the match count. Zero allocs: no intermediate array, one pass.
/// This is the fused scan+format core: callers format inside the sink.
/// Whole-chunk shape: indexOfPos over the buffer, back-scan ls, fwd le,
/// countScalar gap only, emit once per line, pos = le + 1.
/// Lines keep raw bytes including CR: rg keeps ^M, so do we (parity +
/// one less branch per hit). Caller passes has_nul=false for clean
/// chunks to skip the NUL check entirely (one scan per chunk, not hit).
pub fn emit(
    content: []const u8,
    needle: []const u8,
    pair: ?Simd.Pair,
    ctx: anytype,
    comptime onMatch: fn (@TypeOf(ctx), u64, []const u8) void,
) usize {
    if (needle.len == 0 or content.len == 0) return 0;
    // One NUL scan per chunk here, not per hit line: clean corpora pay
    // a single vectorized pass, binary chunks get per-hit suppression.
    const has_nul = std.mem.indexOfScalar(u8, content, 0) != null;
    return emitChunk(content, needle, pair, has_nul, ctx, onMatch);
}

pub fn emitChunk(
    content: []const u8,
    needle: []const u8,
    pair: ?Simd.Pair,
    has_nul: bool,
    ctx: anytype,
    comptime onMatch: fn (@TypeOf(ctx), u64, []const u8) void,
) usize {
    _ = pair;
    if (needle.len == 0 or content.len == 0) return 0;
    // First-byte prefilter for ALL len>=2: memchr skips 32B per iter,
    // one eql verifies. std linear-scans every position for short
    // needles and runs memmem setup for long ones; first-byte wins
    // both (he 128->40, in 109->83). Len 1 falls to generic below.
    if (needle.len >= 2) return emitChunkShort(content, needle, has_nul, ctx, onMatch);
    var total: usize = 0;
    var pos: usize = 0;
    var lineno: u64 = 1;
    while (std.mem.indexOfPos(u8, content, pos, needle)) |m| {
        // Back-scan to line start (never crosses pos: pos is a line start).
        var ls = m;
        while (ls > pos and content[ls - 1] != '\n') ls -= 1;
        const le = std.mem.indexOfScalarPos(u8, content, m, '\n') orelse content.len;
        lineno += std.mem.countScalar(u8, content[pos..ls], '\n');
        if (!has_nul or std.mem.indexOfScalar(u8, content[ls..le], 0) == null) {
            onMatch(ctx, lineno, content[ls..le]);
            total += 1;
        }
        pos = if (le < content.len) le + 1 else content.len;
        lineno += 1;
    }
    return total;
}

fn emitChunkShort(
    content: []const u8,
    needle: []const u8,
    has_nul: bool,
    ctx: anytype,
    comptime onMatch: fn (@TypeOf(ctx), u64, []const u8) void,
) usize {
    const n = needle.len;
    const first = needle[0];
    var total: usize = 0;
    var pos: usize = 0; // scan cursor: m+1, wanders on misses
    var lineno: u64 = 1;
    var lpos: usize = 0; // line start where lineno is exact; gap anchor
    var prev_le: usize = 0; // end of previous verified line (dedupe)
    var have_prev = false;
    while (std.mem.indexOfScalarPos(u8, content, pos, first)) |m| {
        // Reject fast: single eql, no line walk on the misses.
        if (m + n > content.len or !std.mem.eql(u8, content[m..][0..n], needle)) {
            pos = m + 1;
            continue;
        }
        // Same-line dedupe against the previous VERIFIED line (emitted
        // or NUL-suppressed: both set prev_le, so the back-scan below
        // always crosses a newline and finds the true line start).
        if (have_prev and m < prev_le) {
            pos = m + 1;
            continue;
        }
        var ls = m;
        // Floor is lpos (a line start), NOT pos: pos sits mid-line
        // after a hit (dedupe needs m+1), and flooring there clips
        // the line head. lpos is always at or before this line start.
        while (ls > lpos and content[ls - 1] != '\n') ls -= 1;
        const le = std.mem.indexOfScalarPos(u8, content, m, '\n') orelse content.len;
        // lpos is a line start at or before this line: the gap holds
        // exactly the crossed newlines, immune to pos wandering.
        lineno += std.mem.countScalar(u8, content[lpos..ls], '\n');
        if (!has_nul or std.mem.indexOfScalar(u8, content[ls..le], 0) == null) {
            onMatch(ctx, lineno, content[ls..le]);
            total += 1;
            lpos = if (le < content.len) le + 1 else content.len;
            lineno += 1;
        }
        prev_le = le;
        have_prev = true;
        pos = m + 1;
    }
    return total;
}

/// Shifted emit for multi-chunk files: chunk-relative linenos from the
/// scan start at 1, callers add (base - 1) via the ctx base pointer.
/// Whole-file callers pass base=1 (no shift). Carries bump base past
/// consumed newlines between chunks.
pub fn emitShifted(
    content: []const u8,
    needle: []const u8,
    pair: ?Simd.Pair,
    base: u64,
    ctx: anytype,
    comptime onMatch: fn (@TypeOf(ctx), u64, []const u8) void,
) usize {
    const ShiftCtx = struct {
        inner: @TypeOf(ctx),
        base: u64,
        fn shifted(s: *@This(), rel: u64, line: []const u8) void {
            onMatch(s.inner, s.base + rel - 1, line);
        }
    };
    var s = ShiftCtx{ .inner = ctx, .base = base };
    return emit(content, needle, pair, &s, ShiftCtx.shifted);
}

/// One indexOfPos per hit, jump past the line so multi-hit lines = 1.
/// Len>=2 takes the first-byte path for the same reason as emit.
pub fn countChunk(content: []const u8, needle: []const u8) usize {
    if (needle.len == 0 or content.len == 0) return 0;
    if (needle.len >= 2) return countChunkShort(content, needle);
    var total: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, needle)) |m| {
        const le = std.mem.indexOfScalarPos(u8, content, m, '\n') orelse content.len;
        total += 1;
        pos = if (le < content.len) le + 1 else content.len;
    }
    return total;
}

fn countChunkShort(content: []const u8, needle: []const u8) usize {
    const n = needle.len;
    const first = needle[0];
    var total: usize = 0;
    var pos: usize = 0;
    var line_end: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, pos, first)) |m| {
        if (m + n > content.len or !std.mem.eql(u8, content[m..][0..n], needle)) {
            pos = m + 1;
            continue;
        }
        if (m < line_end) {
            pos = m + 1;
            continue;
        }
        const le = std.mem.indexOfScalarPos(u8, content, m, '\n') orelse content.len;
        line_end = le;
        total += 1;
        pos = m + 1;
    }
    return total;
}

/// Chunk-level any-match: stop at first hit anywhere.
pub fn anyChunk(content: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or content.len == 0) return false;
    // Len 1: memchr scalar beats the generic indexOf dispatch.
    if (needle.len == 1) return std.mem.indexOfScalar(u8, content, needle[0]) != null;
    // Len>=2: first-byte skip + eql verify, exit on first confirm.
    // No line walk, no lineno: existence only.
    const n = needle.len;
    const first = needle[0];
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, pos, first)) |m| {
        if (m + n <= content.len and std.mem.eql(u8, content[m..][0..n], needle)) return true;
        pos = m + 1;
    }
    return false;
}

/// Same as search but reuses a precomputed pair. Workers compute the pair
/// once per run instead of once per chunk.
/// Kept for stdin + single-thread paths; worker hot path uses emitChunk.
/// Whole-chunk shape: indexOfPos, back-scan ls, fwd le, countScalar gap,
/// raw bytes with CR kept (rg parity), one NUL scan per line max.
pub fn searchWith(allocator: std.mem.Allocator, content: []const u8, needle: []const u8, pair: ?Simd.Pair) ![]Span {
    _ = pair;
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(allocator);
    if (needle.len == 0 or content.len == 0) return out.toOwnedSlice(allocator);
    var pos: usize = 0;
    var lineno: u64 = 1;
    const has_nul = std.mem.indexOfScalar(u8, content, 0) != null;
    while (std.mem.indexOfPos(u8, content, pos, needle)) |m| {
        var ls = m;
        while (ls > pos and content[ls - 1] != '\n') ls -= 1;
        const le = std.mem.indexOfScalarPos(u8, content, m, '\n') orelse content.len;
        lineno += std.mem.countScalar(u8, content[pos..ls], '\n');
        if (!has_nul or std.mem.indexOfScalar(u8, content[ls..le], 0) == null) {
            try out.append(allocator, .{ .lineno = lineno, .start = ls, .end = le });
        }
        pos = if (le < content.len) le + 1 else content.len;
        lineno += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn count(content: []const u8, needle: []const u8) usize {
    return countChunk(content, needle);
}

/// Count matching lines without allocating spans. Used by -c.
/// Whole-chunk shape; pair kept for call-site compat.
pub fn countWith(content: []const u8, needle: []const u8, pair: ?Simd.Pair) usize {
    _ = pair;
    return countChunk(content, needle);
}

pub fn anyMatch(content: []const u8, needle: []const u8) bool {
    return anyChunk(content, needle);
}

/// True if any matching line exists. Used by -l. Stops at first hit.
/// Whole-buffer indexOf: no line walk at all.
pub fn anyMatchWith(content: []const u8, needle: []const u8, pair: ?Simd.Pair) bool {
    _ = pair;
    return anyChunk(content, needle);
}

test "search: basic line spans" {
    const t = std.testing;
    const buf = "foo one\ntwo foo\nnope\nfoo foo\n";
    const spans = try search(t.allocator, buf, "foo");
    defer t.allocator.free(spans);
    try t.expectEqual(@as(usize, 3), spans.len);
    try t.expectEqual(@as(u64, 1), spans[0].lineno);
    try t.expectEqual(@as(u64, 2), spans[1].lineno);
    try t.expectEqual(@as(u64, 4), spans[2].lineno);
    try t.expectEqualStrings("foo one", buf[spans[0].start..spans[0].end]);
}

test "search: one span per line even with two hits" {
    const t = std.testing;
    const spans = try search(t.allocator, "a foo b foo c\nnext\n", "foo");
    defer t.allocator.free(spans);
    try t.expectEqual(@as(usize, 1), spans.len);
}

test "search: CRLF kept raw like rg" {
    const t = std.testing;
    const buf = "foo bar\r\nnext\n";
    const spans = try search(t.allocator, buf, "foo");
    defer t.allocator.free(spans);
    try t.expectEqual(@as(usize, 1), spans.len);
    try t.expectEqualStrings("foo bar\r", buf[spans[0].start..spans[0].end]);
}

test "search: NUL suppresses matching line only" {
    const t = std.testing;
    const spans = try search(t.allocator, "foo\x00bar\nfoo clean\n", "foo");
    defer t.allocator.free(spans);
    try t.expectEqual(@as(usize, 1), spans.len);
    try t.expectEqual(@as(u64, 2), spans[0].lineno);
}

test "search: empty needle matches nothing" {
    const t = std.testing;
    const spans = try search(t.allocator, "foo\n", "");
    defer t.allocator.free(spans);
    try t.expectEqual(@as(usize, 0), spans.len);
}

test "count and anyMatch agree with search" {
    const t = std.testing;
    const buf = "foo one\ntwo\nfoo two\n";
    try t.expectEqual(@as(usize, 2), count(buf, "foo"));
    try t.expect(anyMatch(buf, "foo"));
    try t.expect(!anyMatch(buf, "zzz"));
    try t.expectEqual(@as(usize, 0), count(buf, "zzz"));
}

test "emit matches search one for one" {
    const t = std.testing;
    const buf = "foo one\ntwo foo\nnope\nfoo foo\n";
    const Ctx = struct {
        lines: std.ArrayList([]const u8) = .empty,
        nos: std.ArrayList(u64) = .empty,
        fn onMatch(self: *@This(), lineno: u64, line: []const u8) void {
            self.lines.append(t.allocator, line) catch {};
            self.nos.append(t.allocator, lineno) catch {};
        }
    };
    var ctx = Ctx{};
    defer ctx.lines.deinit(t.allocator);
    defer ctx.nos.deinit(t.allocator);
    const pair = Simd.pickPair("foo");
    const total = emit(buf, "foo", pair, &ctx, Ctx.onMatch);
    try t.expectEqual(@as(usize, 3), total);
    try t.expectEqualSlices(u64, &.{ 1, 2, 4 }, ctx.nos.items);
    try t.expectEqualStrings("foo one", ctx.lines.items[0]);
    // CRLF kept raw, NUL line suppressed.
    var ctx2 = Ctx{};
    defer ctx2.lines.deinit(t.allocator);
    defer ctx2.nos.deinit(t.allocator);
    const total2 = emit("foo\x00bar\nfoo ok\r\n", "foo", pair, &ctx2, Ctx.onMatch);
    // emit() does one NUL scan per chunk: binary chunk suppresses the
    // NUL line, only the clean line surfaces.
    try t.expectEqual(@as(usize, 1), total2);
    try t.expectEqualStrings("foo ok\r", ctx2.lines.items[0]);
}
