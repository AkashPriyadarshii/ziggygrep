const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

// Recursive walk that pushes each file path into a queue as it is found.
// Skips dotfiles and .git. No gitignore engine in v0.1. The walk runs on
// the main thread while workers consume the queue, so directory traversal
// overlaps scanning instead of running as a serial phase first.

const Push = struct {
    queue: *anyopaque,
    ctx: *anyopaque,
    pushFn: *const fn (q: *anyopaque, ctx: *anyopaque, path: []const u8) void,
};

pub fn pushAll(
    allocator: std.mem.Allocator,
    io: Io,
    roots: []const []const u8,
    comptime kind: SinkKind,
    target: anytype,
) !void {
    for (roots) |root| {
        // Directory fast path first: trailing slash or backslash means
        // dir, skip the stat syscall entirely (rg never stats ".").
        // Explicit files still stat once to confirm they exist.
        if (!isDirPath(root)) {
            const st = Dir.statFile(.cwd(), io, root, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try printMissing(io, root);
                    return error.FileNotFound;
                },
                error.IsDir => null,
                else => return err,
            };
            if (st) |s| {
                if (s.kind != .directory) {
                    try pushPath(kind, target, allocator, root);
                    continue;
                }
            }
        }
        var dir = Dir.openDir(.cwd(), io, root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                try printMissing(io, root);
                return error.FileNotFound;
            },
            else => return err,
        };
        defer dir.close(io);
        var walker = try Dir.walk(dir, allocator);
        defer walker.deinit();
        // Batch joins: reserve one arena per directory walk instead of a
        // fresh join-alloc per file. 200 files * ~12 bytes path = one
        // 4KB block covers every path string with zero per-file malloc.
        var path_arena: [4096]u8 = undefined;
        var arena_off: usize = 0;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (isSkipped(entry.path)) continue;
            const need = root.len + 1 + entry.path.len + 1;
            var full: []const u8 = undefined;
            if (arena_off + need <= path_arena.len) {
                @memcpy(path_arena[arena_off..][0..root.len], root);
                path_arena[arena_off + root.len] = '/';
                @memcpy(path_arena[arena_off + root.len + 1 ..][0..entry.path.len], entry.path);
                full = path_arena[arena_off..][0 .. need - 1];
                arena_off += need;
            } else {
                // Overflow fallback: heap join, same ownership contract.
                full = try std.fs.path.join(allocator, &.{ root, entry.path });
            }
            // Queue takes ownership: dupe arena paths onto the heap so
            // the arena can be reused next directory.
            const owned = if (@intFromPtr(full.ptr) >= @intFromPtr(&path_arena[0]) and
                @intFromPtr(full.ptr) < @intFromPtr(&path_arena[0]) + path_arena.len)
                try allocator.dupe(u8, full)
            else
                full;
            try pushPath(kind, target, allocator, owned);
        }
    }
}

pub const SinkKind = enum { queue, list };

// The ring queue cannot fail on push (it spins when full); the list can
// fail on append, so a failed list push frees the joined path.
fn pushPath(comptime kind: SinkKind, target: anytype, allocator: std.mem.Allocator, owned: []const u8) !void {
    switch (kind) {
        .queue => {
            target.push(owned);
        },
        .list => {
            target.append(allocator, owned) catch |err| {
                allocator.free(owned);
                return err;
            };
        },
    }
}

fn isSkipped(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (part[0] == '.') return true;
    }
    var it2 = std.mem.splitScalar(u8, path, '\\');
    while (it2.next()) |part| {
        if (part.len == 0) continue;
        if (part[0] == '.') return true;
    }
    return false;
}

pub fn isDirPath(path: []const u8) bool {
    // "." itself is always a dir; trailing slashes mark dirs too.
    if (path.len == 1 and path[0] == '.') return true;
    return path.len > 0 and (path[path.len - 1] == '/' or path[path.len - 1] == '\\');
}

fn printMissing(io: Io, path: []const u8) !void {    const stderr = File.stderr();
    var buf: [4096]u8 = undefined;
    var w = stderr.writer(io, &buf);
    w.interface.print("ziggygrep: {s}: no such file or directory\n", .{path}) catch {};
    w.interface.flush() catch {};
}
