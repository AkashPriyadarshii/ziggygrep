const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

const Args = @import("Args.zig");
const Engine = @import("Engine.zig");
const Simd = @import("Simd.zig");
const Walk = @import("Walk.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = Args.parse(gpa, init.minimal.args) catch |err| switch (err) {
        error.UnknownOption, error.InvalidOption => {
            try writeStderr(io, "ziggygrep: unknown or invalid option (try --help)\n");
            std.process.exit(2);
        },
        error.OutOfMemory => {
            try writeStderr(io, "ziggygrep: out of memory\n");
            std.process.exit(2);
        },
    };
    defer args.deinit(gpa);

    if (args.help) {
        try File.stdout().writeStreamingAll(io, help_text);
        return;
    }
    if (args.version) {
        try File.stdout().writeStreamingAll(io, version_text);
        return;
    }

    const pattern = args.pattern orelse {
        try writeStderr(io, "ziggygrep: no pattern (try --help)\n");
        std.process.exit(2);
    };

    // No paths: read stdin, print matches without prefix (grep parity).
    if (args.paths.items.len == 0) {
        const n = readStdin(gpa, io, pattern, &args) catch |err| switch (err) {
            error.BrokenPipe => std.process.exit(141),
            else => {
                try writeStderr(io, "ziggygrep: i/o error\n");
                std.process.exit(2);
            },
        };
        if (n == 0) std.process.exit(1);
        return;
    }

    // Single-file runs omit the path prefix (grep parity). Directory runs
    // and multi-path runs keep it.
    const prefix = args.paths.items.len != 1 or isDirPath(args.paths.items[0]);

    var engine = Engine.Engine{
        .allocator = gpa,
        .io = io,
        .needle = pattern,
        .pair = if (pattern.len >= 2) Simd.pickPair(pattern) else null,
        .files_with_matches = args.files_with_matches,
        .count_mode = args.count,
        .max_columns = args.max_columns,
        .prefix_path = prefix,
    };
    const total = engine.run(args.paths.items) catch |err| switch (err) {
        error.FileNotFound => std.process.exit(2),
        error.OutOfMemory => {
            try writeStderr(io, "ziggygrep: out of memory\n");
            std.process.exit(2);
        },
        else => {
            try writeStderr(io, "ziggygrep: i/o error\n");
            std.process.exit(2);
        },
    };
    if (total == 0) std.process.exit(1);
}

fn isDirPath(path: []const u8) bool {
    return path.len > 0 and (path[path.len - 1] == '/' or path[path.len - 1] == '\\');
}

fn readStdin(
    allocator: std.mem.Allocator,
    _io: Io,
    needle: []const u8,
    args: *const Args,
) !usize {
    _ = _io;
    const IoMod = @import("Io.zig");
    const Search = @import("Search.zig");
    const Out = @import("Out.zig");

    const fd = IoMod.fd_of.get(File.stdin().handle);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var buf: [1048576]u8 = undefined;
    while (true) {
        const n = IoMod.raw_io.read(fd, &buf) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
        if (n == 0) break;
        try content.appendSlice(allocator, buf[0..n]);
    }

    var w = Out.Writer.init(IoMod.fd_of.get(File.stdout().handle), false);
    if (args.count) {
        const n = Search.count(content.items, needle);
        try w.printCount("", n, false);
        try w.flush();
        return n;
    }
    if (args.files_with_matches) {
        try w.flush();
        return if (Search.anyMatch(content.items, needle)) 1 else 0;
    }
    const SearchMod = @import("Search.zig");
    const spans = try SearchMod.search(allocator, content.items, needle);
    defer allocator.free(spans);
    for (spans) |s| {
        try w.printMatch("(standard input)", s.lineno, content.items[s.start..s.end], args.max_columns);
    }
    try w.flush();
    return spans.len;
}

fn writeStderr(io: Io, msg: []const u8) !void {
    File.stderr().writeStreamingAll(io, msg) catch {};
}

const help_text =
    \\ziggygrep v0.1.0 - Fast grep replacement in pure Zig
    \\
    \\Usage: ziggygrep [OPTIONS] PATTERN [PATH...]
    \\
    \\Search files for a literal pattern. No regex, no index, no daemon.
    \\
    \\Options:
    \\  -l, --files-with-matches  Print only names of files with matches
    \\  -c, --count               Print match counts per file
    \\  -M N, --max-columns N     Truncate lines longer than N columns (0 disables)
    \\  -h, --help                Display this help and exit
    \\  -V, --version             Display version and exit
    \\
    \\Exit codes: 0 match found, 1 no match, 2 error.
    \\
    \\Examples:
    \\  ziggygrep HashMap .          Search current directory
    \\  ziggygrep -l TODO src/       Files containing TODO
    \\  ziggygrep -c foo file.txt    Count matches per file
    \\
;

const version_text = "ziggygrep 0.1.0\n";
