const std = @import("std");
const Io = std.Io;
const File = Io.File;
const IoMod = @import("Io.zig");
const Search = @import("Search.zig");

// Output formatting + buffered single-flush writes. One lock, one flush,
// no per-line syscalls. Mirrors ziggycat's proven Out sink.

// ponytail: 60KB chunks, proven against MSYS pipe rejection above 64KB.
pub const Writer = struct {
    out: IoMod.Out,
    prefix_path: bool,

    pub fn init(stdout_fd: usize, prefix_path: bool) Writer {
        return .{ .out = IoMod.Out.init(stdout_fd), .prefix_path = prefix_path };
    }

    pub fn flush(self: *Writer) !void {
        try self.out.flush();
    }

    pub fn printMatch(
        self: *Writer,
        path: []const u8,
        lineno: u64,
        line: []const u8,
        max_columns: usize,
    ) !void {
        if (self.prefix_path) {
            try self.out.writeAll(path);
            try self.out.writeByte(':');
        }
        try writeU64(&self.out, lineno);
        try self.out.writeByte(':');
        try self.writeTruncated(line, max_columns);
        try self.out.writeByte('\n');
    }

    pub fn printPath(self: *Writer, path: []const u8) !void {
        try self.out.writeAll(path);
        try self.out.writeByte('\n');
    }

    pub fn printMatchShifted(
        self: *Writer,
        path: []const u8,
        lineno: u64,
        line: []const u8,
        max_columns: usize,
    ) !void {
        // Stack-header fast path: path + digits + ':' in one copy,
        // mirrors the pool-path fused Ctx. prefix_path honored.
        var head: [520]u8 = undefined;
        var hlen: usize = 0;
        if (self.prefix_path and path.len + 24 <= head.len) {
            @memcpy(head[0..path.len], path);
            hlen = path.len;
            head[hlen] = ':';
            hlen += 1;
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
            try self.out.writeAll(head[0..hlen]);
        } else {
            if (self.prefix_path) {
                try self.out.writeAll(path);
                try self.out.writeByte(':');
            }
            try writeU64(&self.out, lineno);
            try self.out.writeByte(':');
        }
        try self.writeTruncated(line, max_columns);
        try self.out.writeByte('\n');
    }

    pub fn printCount(self: *Writer, path: []const u8, n: usize, show_path: bool) !void {
        if (show_path) {
            try self.out.writeAll(path);
            try self.out.writeByte(':');
        }
        try writeU64(&self.out, n);
        try self.out.writeByte('\n');
    }

    fn writeTruncated(self: *Writer, line: []const u8, max_columns: usize) !void {
        if (max_columns == 0 or line.len <= max_columns) {
            return self.out.writeAll(line);
        }
        // Cut on a UTF-8 boundary: back off past continuation bytes.
        var end = max_columns;
        while (end > 0 and (line[end] & 0xC0) == 0x80) end -= 1;
        try self.out.writeAll(line[0..end]);
    }
};

fn writeU64(out: *IoMod.Out, n: u64) !void {
    if (n == 0) {
        try out.writeByte('0');
        return;
    }
    var tmp: [20]u8 = undefined;
    var v = n;
    var i: usize = 20;
    while (v > 0) : (v /= 10) {
        i -= 1;
        tmp[i] = @intCast('0' + (v % 10));
    }
    try out.writeAll(tmp[i..20]);
}
