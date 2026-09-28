const std = @import("std");
const builtin = @import("builtin");

pub const Args = @This();

pub fn parse(allocator: std.mem.Allocator, args: std.process.Args) !Args {
    var result = Args{
        .paths = .empty,
    };

    var iter = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer iter.deinit();

    _ = iter.next(); // skip program name

    var parsing_flags = true;

    while (iter.next()) |arg| {
        if (!parsing_flags) {
            if (result.pattern == null) {
                result.pattern = try allocator.dupe(u8, arg);
            } else {
                try result.paths.append(allocator, try allocator.dupe(u8, arg));
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            parsing_flags = false;
        } else if (std.mem.eql(u8, arg, "--files-with-matches")) {
            result.files_with_matches = true;
        } else if (std.mem.eql(u8, arg, "--count")) {
            result.count = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            result.help = true;
            return result;
        } else if (std.mem.eql(u8, arg, "--version")) {
            result.version = true;
            return result;
        } else if (std.mem.startsWith(u8, arg, "--max-columns=")) {
            result.max_columns = std.fmt.parseInt(usize, arg["--max-columns=".len..], 10) catch
                return error.InvalidOption;
        } else if (std.mem.eql(u8, arg, "--max-columns")) {
            const val = iter.next() orelse return error.InvalidOption;
            result.max_columns = std.fmt.parseInt(usize, val, 10) catch
                return error.InvalidOption;
        } else if (std.mem.startsWith(u8, arg, "--") and arg.len > 2) {
            return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "-")) {
            try result.paths.append(allocator, try allocator.dupe(u8, arg));
        } else if (std.mem.eql(u8, arg, "-M")) {
            const val = iter.next() orelse return error.InvalidOption;
            result.max_columns = std.fmt.parseInt(usize, val, 10) catch
                return error.InvalidOption;
        } else if (std.mem.startsWith(u8, arg, "-M") and arg.len > 2) {
            result.max_columns = std.fmt.parseInt(usize, arg[2..], 10) catch
                return error.InvalidOption;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                switch (arg[i]) {
                    'l' => result.files_with_matches = true,
                    'c' => result.count = true,
                    'h' => {
                        result.help = true;
                        return result;
                    },
                    'V' => {
                        result.version = true;
                        return result;
                    },
                    else => return error.UnknownOption,
                }
            }
        } else if (result.pattern == null) {
            result.pattern = try allocator.dupe(u8, arg);
        } else {
            try result.paths.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    return result;
}

pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
    if (self.pattern) |p| allocator.free(p);
    for (self.paths.items) |p| allocator.free(p);
    self.paths.deinit(allocator);
}

help: bool = false,
version: bool = false,
files_with_matches: bool = false,
count: bool = false,
max_columns: usize = 0, // 0 = no truncation
pattern: ?[]const u8 = null,
paths: std.ArrayList([]const u8) = .empty,

fn testArgs(allocator: std.mem.Allocator, cmdline: []const u8) !Args {
    const cmd = try std.unicode.utf8ToUtf16LeAlloc(allocator, cmdline);
    defer allocator.free(cmd);
    return try parse(allocator, .{ .vector = cmd });
}

test "parse: pattern + path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var a = try testArgs(std.testing.allocator, "ziggygrep HashMap src/");
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("HashMap", a.pattern.?);
    try std.testing.expectEqual(@as(usize, 1), a.paths.items.len);
}

test "parse: -l -c flags" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var a = try testArgs(std.testing.allocator, "ziggygrep -l HashMap .");
    defer a.deinit(std.testing.allocator);
    try std.testing.expect(a.files_with_matches);
    try std.testing.expectEqualStrings("HashMap", a.pattern.?);
}

test "parse: -M forms" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var a = try testArgs(std.testing.allocator, "ziggygrep -M200 foo .");
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 200), a.max_columns);
    var b = try testArgs(std.testing.allocator, "ziggygrep -M 200 foo .");
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 200), b.max_columns);
    var c = try testArgs(std.testing.allocator, "ziggygrep --max-columns=0 foo .");
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), c.max_columns);
}

test "parse: unknown option errors" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectError(error.UnknownOption, testArgs(std.testing.allocator, "ziggygrep -z foo"));
    try std.testing.expectError(error.UnknownOption, testArgs(std.testing.allocator, "ziggygrep --bogus foo"));
}

test "parse: -- ends flag parsing, pattern is literal" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var a = try testArgs(std.testing.allocator, "ziggygrep -- -weird .");
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("-weird", a.pattern.?);
}
