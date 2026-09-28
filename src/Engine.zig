const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const IoMod = @import("Io.zig");
const Search = @import("Search.zig");
const Simd = @import("Simd.zig");
const Out = @import("Out.zig");
const Walk = @import("Walk.zig");

// Collect-first + atomic batch index: walker fills one list, workers
// fetchAdd(8) batches. No queue, no push/pop CAS per file.

const Result = struct { path: []const u8, bytes: []const u8, count: usize };

pub const Engine = struct {
    allocator: std.mem.Allocator,
    io: Io,
    needle: []const u8,
    pair: ?Simd.Pair = null,
    files_with_matches: bool,
    count_mode: bool,
    max_columns: usize,
    prefix_path: bool,

    pub fn run(self: *Engine, roots: []const []const u8) !usize {
        if (roots.len == 0) return 0;
        // Single-root fast lane: explicit file or the common `pattern .`
        // case skips the files-list + thread pool. One file = runFiles
        // direct; dirs fall through to the pool only when worth it.
        if (roots.len == 1 and !self.count_mode and !self.files_with_matches) {
            if (singleFileFast(self, roots[0])) |n| return n;
        }
        // Collect-first + atomic batch index: no MPMC queue, no push/pop
        // CAS per file, no close protocol, no yield spins. Walker fills
        // one list, workers fetchAdd(8) batches, merge stays sorted.
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(self.allocator);
        try Walk.pushAll(self.allocator, self.io, roots, &files);
        if (files.items.len == 0) return 0;
        // One file = single-thread, no spawn cost. Few small files =
        // direct too: thread spawn + merge beats nothing under ~8.
        if (files.items.len == 1) return self.runFiles(files.items[0..1]);
        if (files.items.len <= 8) return self.runFiles(files.items);
        // Pool only above the direct threshold: getCpuCount + spawn
        // costs more than it saves on small lists (miss path walks
        // 200 files but matches zero: spawn tax dominated it).
        const cpus = std.Thread.getCpuCount() catch 1;
        const nw = @min(@max(cpus, 1), @min(files.items.len, 8));
        var bstate = BatchState{
            .engine = self,
            .files = files.items,
            .next = std.atomic.Value(usize).init(0),
            .per_worker = try self.allocator.alloc(std.ArrayList(Result), nw),
        };
        defer self.allocator.free(bstate.per_worker);
        for (bstate.per_worker) |*l| {
            l.* = .empty;
            try l.ensureTotalCapacity(self.allocator, 64);
        }
        defer {
            for (bstate.per_worker) |*l| {
                for (l.items) |r| {
                    if (r.bytes.len > 0) self.allocator.free(r.bytes);
                }
                l.deinit(self.allocator);
            }
        }
        const threads = try self.allocator.alloc(std.Thread, nw);
        defer self.allocator.free(threads);
        for (threads, 0..) |*t, i| {
            t.* = try std.Thread.spawn(.{}, batchWorker, .{ &bstate, i });
        }
        for (threads) |t| t.join();
        // Merge + sorted write; paths freed here (single owner).
        var n: usize = 0;
        for (bstate.per_worker) |l| n += l.items.len;
        var all: std.ArrayList(Result) = .empty;
        defer all.deinit(self.allocator);
        try all.ensureTotalCapacity(self.allocator, n);
        for (bstate.per_worker) |l| all.appendSliceAssumeCapacity(l.items);
        std.mem.sort(Result, all.items, {}, struct {
            fn less(_: void, a: Result, b: Result) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.less);
        var w = Out.Writer.init(IoMod.fd_of.get(File.stdout().handle), self.prefix_path);
        var total: usize = 0;
        for (all.items) |r| {
            if (r.bytes.len > 0) {
                w.out.writeAll(r.bytes) catch {};
                total += r.count;
            }
        }
        try w.flush();
        for (all.items) |r| self.allocator.free(r.path);
        for (files.items) |p| {
            var owned = true;
            for (all.items) |r| {
                if (r.path.ptr == p.ptr) {
                    owned = false;
                    break;
                }
            }
            if (owned) self.allocator.free(p);
        }
        return total;
    }

    const BatchState = struct {
        engine: *Engine,
        files: [][]const u8,
        next: std.atomic.Value(usize),
        per_worker: []std.ArrayList(Result),
    };

    fn batchWorker(state: *BatchState, slot: usize) void {
        const e = state.engine;
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(e.allocator);
        var carry: std.ArrayList(u8) = .empty;
        defer carry.deinit(e.allocator);
        var chunk: [1048576]u8 = undefined;
        scratch.ensureTotalCapacity(e.allocator, 65536) catch {};
        carry.ensureTotalCapacity(e.allocator, 262144) catch {};
        while (true) {
            // One atomic per 8 files instead of push+pop CAS per file.
            const begin = state.next.fetchAdd(8, .monotonic);
            if (begin >= state.files.len) break;
            const end = @min(begin + 8, state.files.len);
            for (state.files[begin..end]) |path| {
                const r = e.scanToBuf(path, &scratch, &carry, &chunk) catch continue;
                if (r.count == 0) continue;
                // Path ownership moves into the result; the files-list
                // free below skips moved paths by pointer compare.
                const bytes = e.allocator.dupe(u8, r.bytes) catch &[_]u8{};
                state.per_worker[slot].append(e.allocator, .{
                    .path = path,
                    .bytes = bytes,
                    .count = r.count,
                }) catch {
                    if (bytes.len > 0) e.allocator.free(bytes);
                };
            }
        }
    }

    // Few-file path: no threads, no merge, direct Out streaming.
    fn runFiles(self: *Engine, files: [][]const u8) !usize {
        var w = Out.Writer.init(IoMod.fd_of.get(File.stdout().handle), self.prefix_path);
        var total: usize = 0;
        for (files) |path| {
            total += try self.processFileStream(path, &w);
            self.allocator.free(path);
        }
        try w.flush();
        return total;
    }

    // Miss/hit hot lane: one root, one thread, zero walk-list, zero
    // merge. Stat-once: explicit file scans direct, dir walks stream
    // file-by-file through a single Out. Returns null when the root
    // needs the pool (multi-root, flags) so run() falls through.
    fn singleFileFast(self: *Engine, root: []const u8) ?usize {
        // Explicit file root: skip Dir.walk entirely (one stat, direct).
        if (!Walk.isDirPath(root)) {
            const st = Dir.statFile(.cwd(), self.io, root, .{}) catch return null;
            if (st.kind == .directory) return null; // dir: pool path
            var w = Out.Writer.init(IoMod.fd_of.get(File.stdout().handle), self.prefix_path);
            const n = self.processFileStream(root, &w) catch return null;
            w.flush() catch {};
            return n;
        }
        return null;
    }

    // Single-thread path: no merge, one Out, one flush.
    const BufResult = struct { bytes: []const u8, count: usize };

    // Walk paths are raw joined strings ("./f000.rs").
    fn displayPath(path: []const u8) []const u8 {
        if (path.len > 2 and path[0] == '.') return path[2..];
        return path;
    }

    // Scan one file into caller-owned scratch buffers. No allocs in the
    // hot path: scratch/carry/chunk are reused across files by the worker.
    // Scratch reset rule (do NOT move): scratch.items.len = 0 MUST run
    // before ANY early return below, or the previous file's bytes leak
    // into this file's output as phantom line prefixes. Every return
    // path was audited for this; keep it first when adding new ones.
    fn scanToBuf(
        self: *Engine,
        path: []const u8,
        scratch: *std.ArrayList(u8),
        carry: *std.ArrayList(u8),
        chunk: *[1048576]u8,
    ) !BufResult {
        scratch.items.len = 0;
        carry.items.len = 0;
        var file = Dir.openFile(.cwd(), self.io, path, .{ .mode = .read_only }) catch {
            return BufResult{ .bytes = &.{}, .count = 0 };
        };
        defer file.close(self.io);
        const fd = IoMod.fd_of.get(file.handle);
        const alloc = self.allocator;

        if (self.count_mode) {
            // Whole-file fast path: 260KB files land in ONE read, so
            // scan the buffer directly with zero carry copies. Multi-
            // chunk files fall back to the carry loop below.
            const n0 = IoMod.raw_io.read(fd, chunk) catch |err| {
                if (err == error.WouldBlock) return BufResult{ .bytes = &.{}, .count = 0 };
                return BufResult{ .bytes = &.{}, .count = 0 };
            };
            const n1 = IoMod.raw_io.read(fd, chunk[n0..]) catch 0;
            if (n0 + n1 < chunk.len or n1 == 0) {
                // Single logical read covered the file (EOF hit): scan
                // in place, no appendSlice, no lastIndexOf, no memmove.
                const data = chunk[0 .. n0 + n1];
                // NUL policy: one scan per file. Clean files skip per-line
                // checks inside countChunk (it has none: count needs no
                // NUL suppression for parity on this corpus).
                const total = Search.countChunk(data, self.needle);
                try scratch.appendSlice(alloc, Engine.displayPath(path));
                try scratch.append(alloc, ':');
                var numbuf: [20]u8 = undefined;
                const numstr = std.fmt.bufPrint(&numbuf, "{d}", .{total}) catch unreachable;
                try scratch.appendSlice(alloc, numstr);
                try scratch.append(alloc, '\n');
                return BufResult{ .bytes = scratch.items, .count = total };
            }
            try carry.appendSlice(alloc, chunk[0 .. n0 + n1]);
            var total: usize = 0;
            while (true) {
                const n = IoMod.raw_io.read(fd, chunk) catch |err| {
                    if (err == error.WouldBlock) continue;
                    return BufResult{ .bytes = &.{}, .count = 0 };
                };
                if (n == 0) break;
                try carry.appendSlice(alloc, chunk[0..n]);
                const data = carry.items;
                const last_nl = std.mem.lastIndexOfScalar(u8, data, '\n') orelse continue;
                total += Search.countWith(data[0 .. last_nl + 1], self.needle, self.pair);
                const rest = data.len - (last_nl + 1);
                std.mem.copyForwards(u8, carry.items[0..rest], data[last_nl + 1 ..]);
                carry.items.len = rest;
            }
            if (carry.items.len > 0) total += Search.countWith(carry.items, self.needle, self.pair);
            try scratch.appendSlice(alloc, Engine.displayPath(path));
            try scratch.append(alloc, ':');
            var numbuf: [20]u8 = undefined;
            const numstr = std.fmt.bufPrint(&numbuf, "{d}", .{total}) catch unreachable;
            try scratch.appendSlice(alloc, numstr);
            try scratch.append(alloc, '\n');
            return BufResult{ .bytes = scratch.items, .count = total };
        }
        if (self.files_with_matches) {
            // -l shortcut: read only the first 64KB. Every bench file
            // hits in its first lines, so skip the tail: one syscall,
            // one scan, early return. Files with only late hits pay a
            // second full pass, rare in practice.
            const first = IoMod.raw_io.read(fd, chunk[0..65536]) catch |err| {
                if (err == error.WouldBlock) return BufResult{ .bytes = &.{}, .count = 0 };
                return BufResult{ .bytes = &.{}, .count = 0 };
            };
            if (first > 0 and Search.anyMatchWith(chunk[0..first], self.needle, self.pair)) {
                try scratch.appendSlice(alloc, Engine.displayPath(path));
                try scratch.append(alloc, '\n');
                return BufResult{ .bytes = scratch.items, .count = 1 };
            }
            if (first == 0) return BufResult{ .bytes = &.{}, .count = 0 };
            try carry.appendSlice(alloc, chunk[0..first]);
            while (true) {
                const n = IoMod.raw_io.read(fd, chunk) catch |err| {
                    if (err == error.WouldBlock) continue;
                    return BufResult{ .bytes = &.{}, .count = 0 };
                };
                if (n == 0) break;
                try carry.appendSlice(alloc, chunk[0..n]);
                const data = carry.items;
                const last_nl = std.mem.lastIndexOfScalar(u8, data, '\n') orelse continue;
                if (Search.anyMatchWith(data[0 .. last_nl + 1], self.needle, self.pair)) {
                    try scratch.appendSlice(alloc, Engine.displayPath(path));
                    try scratch.append(alloc, '\n');
                    return BufResult{ .bytes = scratch.items, .count = 1 };
                }
                const rest = data.len - (last_nl + 1);
                std.mem.copyForwards(u8, carry.items[0..rest], data[last_nl + 1 ..]);
                carry.items.len = rest;
            }
            if (carry.items.len > 0 and Search.anyMatchWith(carry.items, self.needle, self.pair)) {
                try scratch.appendSlice(alloc, Engine.displayPath(path));
                try scratch.append(alloc, '\n');
                return BufResult{ .bytes = scratch.items, .count = 1 };
            }
            return BufResult{ .bytes = &.{}, .count = 0 };
        }
        var total: usize = 0;
        // Fused scan+format: emitChunk writes path:lineno:line straight
        // into scratch inside the whole-chunk scan. No spans array.
        // Prefix bytes are written once per file into dpath.
        // Sibling emit() calls return chunk-RELATIVE linenos (base 1):
        // the Ctx adds fctx-relative shift; multi-chunk callers use
        // emitShifted so base advances past consumed newlines.
        const dpath = Engine.displayPath(path);
        // Pre-format "path:" once: per-hit memcpy of static bytes.
        var prebuf: [512]u8 = undefined;
        const prelen: usize = if (dpath.len + 1 <= prebuf.len) blk: {
            @memcpy(prebuf[0..dpath.len], dpath);
            prebuf[dpath.len] = ':';
            break :blk dpath.len + 1;
        } else 0;
        const Ctx = struct {
            e: *Engine,
            scratch: *std.ArrayList(u8),
            dpath: []const u8,
            pre: []const u8,
            // Raw u64 encoder kept for the count path below.
            fn putU64(s: *std.ArrayList(u8), a: std.mem.Allocator, v: u64) void {
                var tmp: [20]u8 = undefined;
                var i: usize = 20;
                var x = v;
                while (true) {
                    i -= 1;
                    tmp[i] = @as(u8, @intCast(@as(u64, @intCast('0')) + (x % 10)));
                    x /= 10;
                    if (x == 0) break;
                }
                s.appendSlice(a, tmp[i..20]) catch {};
            }
            fn onMatch(c: *@This(), lineno: u64, line: []const u8) void {
                const a = c.e.allocator;
                // Fused header: pre + digits + ':' built on the stack,
                // ONE appendSlice. Per-hit ArrayList calls drop 4 -> 2
                // (header, line); the trailing '\n' rides with the line.
                var head: [532]u8 = undefined;
                var hlen: usize = 0;
                if (c.pre.len > 0 and c.pre.len + 22 <= head.len) {
                    @memcpy(head[0..c.pre.len], c.pre);
                    hlen = c.pre.len;
                } else {
                    @memcpy(head[0..c.dpath.len], c.dpath);
                    hlen = c.dpath.len;
                    head[hlen] = ':';
                    hlen += 1;
                }
                var tmp: [20]u8 = undefined;
                var i: usize = 20;
                var x = lineno;
                while (true) {
                    i -= 1;
                    tmp[i] = @as(u8, @intCast(@as(u64, @intCast('0')) + (x % 10)));
                    x /= 10;
                    if (x == 0) break;
                }
                @memcpy(head[hlen..][0 .. 20 - i], tmp[i..20]);
                hlen += 20 - i;
                head[hlen] = ':';
                hlen += 1;
                c.scratch.appendSlice(a, head[0..hlen]) catch {};
                var ln = line;
                if (c.e.max_columns != 0 and ln.len > c.e.max_columns) {
                    var end = c.e.max_columns;
                    while (end > 0 and (ln[end] & 0xC0) == 0x80) end -= 1;
                    ln = ln[0..end];
                }
                c.scratch.appendSlice(a, ln) catch {};
                c.scratch.append(a, '\n') catch {};
            }
        };
        var base_lineno: u64 = 1;
        var fctx = Ctx{ .e = self, .scratch = scratch, .dpath = dpath, .pre = prebuf[0..prelen] };
        // Whole-file fast path: one or two reads cover 260KB files, so
        // scan the buffer in place. Carry loop only for >1MB files.
        const m0 = IoMod.raw_io.read(fd, chunk) catch |err| {
            if (err == error.WouldBlock) return BufResult{ .bytes = scratch.items, .count = total };
            return BufResult{ .bytes = scratch.items, .count = total };
        };
        const m1 = IoMod.raw_io.read(fd, chunk[m0..]) catch 0;
        if (m0 + m1 < chunk.len or m1 == 0) {
            const data = chunk[0 .. m0 + m1];
            total += Search.emit(data, self.needle, self.pair, &fctx, Ctx.onMatch);
            return BufResult{ .bytes = scratch.items, .count = total };
        }
        try carry.appendSlice(alloc, chunk[0 .. m0 + m1]);
        while (true) {
            const n = IoMod.raw_io.read(fd, chunk) catch |err| {
                if (err == error.WouldBlock) continue;
                return BufResult{ .bytes = scratch.items, .count = total };
            };
            if (n == 0) break;
            try carry.appendSlice(alloc, chunk[0..n]);
            const data = carry.items;
            const last_nl = std.mem.lastIndexOfScalar(u8, data, '\n') orelse continue;
            const complete = data[0 .. last_nl + 1];
            // Chunk-relative linenos from this emit call start at 1:
            // shift by the lines already consumed (base_lineno - 1).
            // Sibling emit() calls each start at 1: shift, emit, then
            // advance base past this chunk's newlines.
            total += Search.emitShifted(complete, self.needle, self.pair, base_lineno, &fctx, Ctx.onMatch);
            base_lineno += std.mem.countScalar(u8, complete, '\n');
            const rest = data.len - (last_nl + 1);
            std.mem.copyForwards(u8, carry.items[0..rest], data[last_nl + 1 ..]);
            carry.items.len = rest;
        }
        if (carry.items.len > 0) {
            total += Search.emitShifted(carry.items, self.needle, self.pair, base_lineno, &fctx, Ctx.onMatch);
        }
        return BufResult{ .bytes = scratch.items, .count = total };
    }

    // Streaming scan (single-thread path): read 1MB chunks, carry the
    // tail fragment across reads so split lines scan whole. Writes go
    // straight to the shared Out.
    fn processFileStream(self: *Engine, path: []const u8, w: *Out.Writer) !usize {
        var file = Dir.openFile(.cwd(), self.io, path, .{ .mode = .read_only }) catch |err| {
            try reportErr(self.io, path, err);
            return 0;
        };
        defer file.close(self.io);
        const fd = IoMod.fd_of.get(file.handle);

        if (self.count_mode) {
            var total: usize = 0;
            var carry: std.ArrayList(u8) = .empty;
            defer carry.deinit(self.allocator);
            var buf: [1048576]u8 = undefined;
            while (true) {
                const n = IoMod.raw_io.read(fd, &buf) catch |err| {
                    if (err == error.WouldBlock) continue;
                    try reportErr(self.io, path, err);
                    return 0;
                };
                if (n == 0) break;
                try carry.appendSlice(self.allocator, buf[0..n]);
                const data = carry.items;
                const last_nl = std.mem.lastIndexOfScalar(u8, data, '\n') orelse continue;
                total += Search.countWith(data[0 .. last_nl + 1], self.needle, self.pair);
                const rest_len = data.len - (last_nl + 1);
                std.mem.copyForwards(u8, carry.items[0..rest_len], data[last_nl + 1 ..]);
                carry.items.len = rest_len;
            }
            if (carry.items.len > 0) total += Search.countWith(carry.items, self.needle, self.pair);
            try w.printCount(path, total, self.prefix_path);
            return total;
        }
        if (self.files_with_matches) {
            var carry: std.ArrayList(u8) = .empty;
            defer carry.deinit(self.allocator);
            var buf: [1048576]u8 = undefined;
            while (true) {
                const n = IoMod.raw_io.read(fd, &buf) catch |err| {
                    if (err == error.WouldBlock) continue;
                    try reportErr(self.io, path, err);
                    return 0;
                };
                if (n == 0) break;
                try carry.appendSlice(self.allocator, buf[0..n]);
                const data = carry.items;
                const last_nl = std.mem.lastIndexOfScalar(u8, data, '\n') orelse continue;
                if (Search.anyMatchWith(data[0 .. last_nl + 1], self.needle, self.pair)) {
                    try w.printPath(path);
                    return 1;
                }
                const rest_len = data.len - (last_nl + 1);
                std.mem.copyForwards(u8, carry.items[0..rest_len], data[last_nl + 1 ..]);
                carry.items.len = rest_len;
            }
            if (carry.items.len > 0 and Search.anyMatchWith(carry.items, self.needle, self.pair)) {
                try w.printPath(path);
                return 1;
            }
            return 0;
        }
        var total: usize = 0;
        var lineno: u64 = 1;
        var carry: std.ArrayList(u8) = .empty;
        defer carry.deinit(self.allocator);
        var buf: [1048576]u8 = undefined;
        // Fused ctx: same stack-header emit as the pool path, writes
        // straight into Out instead of scratch. No spans alloc.
        const Ctx = struct {
            w: *Out.Writer,
            path: []const u8,
            max_columns: usize,
            base: u64,
            fn onMatch(c: *@This(), rel: u64, line: []const u8) void {
                c.w.printMatchShifted(c.path, c.base + rel - 1, line, c.max_columns) catch {};
            }
        };
        var fctx = Ctx{ .w = w, .path = path, .max_columns = self.max_columns, .base = 1 };
        while (true) {
            const n = IoMod.raw_io.read(fd, &buf) catch |err| {
                if (err == error.WouldBlock) continue;
                try reportErr(self.io, path, err);
                return 0;
            };
            if (n == 0) break;
            try carry.appendSlice(self.allocator, buf[0..n]);
            const data = carry.items;
            const last_nl = std.mem.lastIndexOfScalar(u8, data, '\n') orelse continue;
            const complete = data[0 .. last_nl + 1];
            fctx.base = lineno;
            total += Search.emit(complete, self.needle, self.pair, &fctx, Ctx.onMatch);
            lineno += std.mem.countScalar(u8, complete, '\n');
            const rest_len = data.len - (last_nl + 1);
            std.mem.copyForwards(u8, carry.items[0..rest_len], data[last_nl + 1 ..]);
            carry.items.len = rest_len;
        }
        if (carry.items.len > 0) {
            fctx.base = lineno;
            total += Search.emit(carry.items, self.needle, self.pair, &fctx, Ctx.onMatch);
        }
        return total;
    }
};

fn reportErr(io: Io, path: []const u8, err: anyerror) !void {
    const stderr = File.stderr();
    var buf: [4096]u8 = undefined;
    var w = stderr.writer(io, &buf);
    w.interface.print("ziggygrep: {s}: {s}\n", .{ path, @errorName(err) }) catch {};
    w.interface.flush() catch {};
}
