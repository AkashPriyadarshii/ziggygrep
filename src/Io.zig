const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

const is_windows = builtin.os.tag == .windows;

// Buffered stdout sink backed by raw kernel32/posix writes. Internal
// accumulation is 256KB (fewer syscalls on 11-60MB outputs); the
// transport chunk stays pipe-safe: regular files/null take the whole
// buffer, pipes cap WriteFile at 60KB (MSYS rejects above 64KB).
// Handle type is detected once at init via GetFileType.
pub const Out = struct {
    data: [262144]u8 = undefined,
    len: usize = 0,
    fd: usize,
    is_pipe: bool,
    const buf_cap: usize = 262144;
    const pipe_chunk: usize = 60000;

    pub fn init(fd: usize) Out {
        return .{ .fd = fd, .is_pipe = raw_io.isPipe(fd) };
    }

    pub fn writeAll(self: *Out, bytes: []const u8) !void {
        var rest = bytes;
        while (true) {
            const free = buf_cap - self.len;
            if (rest.len <= free) {
                @memcpy(self.data[self.len..][0..rest.len], rest);
                self.len += rest.len;
                return;
            }
            @memcpy(self.data[self.len..][0..free], rest[0..free]);
            self.len = buf_cap;
            try self.flush();
            rest = rest[free..];
        }
    }

    pub inline fn writeByte(self: *Out, byte: u8) !void {
        if (self.len == buf_cap) try self.flush();
        self.data[self.len] = byte;
        self.len += 1;
    }

    pub fn flush(self: *Out) !void {
        if (self.len == 0) return;
        if (self.is_pipe) {
            // Pipe transport: 60KB WriteFile chunks.
            var off: usize = 0;
            while (off < self.len) {
                const end = @min(off + pipe_chunk, self.len);
                try raw_io.writeAll(self.fd, self.data[off..end]);
                off = end;
            }
        } else {
            try raw_io.writeAll(self.fd, self.data[0..self.len]);
        }
        self.len = 0;
    }
};

pub const fd_of = if (is_windows) struct {
    // File.handle is a *anyopaque (HANDLE) on Windows.
    pub fn get(h: anytype) usize {
        return @intFromPtr(h);
    }
} else struct {
    // File.handle is an fd_t (i32) on POSIX.
    pub fn get(h: anytype) usize {
        return @intCast(h);
    }
};

// Direct fd I/O: std.posix lacks read/write on Windows, so bind kernel32
// (NT layer only if needed later); POSIX uses std.posix. Avoids the extra
// memcpy of the buffered std.Io path.
pub const raw_io = if (is_windows) struct {
    extern "kernel32" fn ReadFile(
        hFile: usize,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(
        hFile: usize,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn GetFileType(hFile: usize) callconv(.winapi) u32;

    const ERROR_BROKEN_PIPE: u32 = 0x6D;
    const ERROR_NO_DATA: u32 = 0xE8;
    const FILE_TYPE_CHAR: u32 = 0x0002;
    const FILE_TYPE_PIPE: u32 = 0x0003;

    pub fn isPipe(hFile: usize) bool {
        const t = GetFileType(hFile);
        return t == FILE_TYPE_CHAR or t == FILE_TYPE_PIPE;
    }

    pub fn read(hFile: usize, buf: []u8) !usize {
        var n: u32 = 0;
        if (ReadFile(hFile, buf.ptr, @intCast(buf.len), &n, null) == 0) {
            switch (GetLastError()) {
                ERROR_BROKEN_PIPE, ERROR_NO_DATA => return 0,
                else => return error.InputOutput,
            }
        }
        return n;
    }

    pub fn writeAll(hFile: usize, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = try write(hFile, rest);
            rest = rest[n..];
        }
    }

    pub fn write(hFile: usize, bytes: []const u8) !usize {
        var n: u32 = 0;
        if (WriteFile(hFile, bytes.ptr, @intCast(bytes.len), &n, null) == 0) {
            switch (GetLastError()) {
                ERROR_BROKEN_PIPE, ERROR_NO_DATA => return error.BrokenPipe,
                else => return error.InputOutput,
            }
        }
        if (n == 0) return error.InputOutput; // 0-byte "success" would spin writeAll
        return n;
    }
} else struct {
    // std.posix.write was removed in 0.16 (write goes through evented Io).
    // No-libc raw write needs a direct syscall, arch + OS keyed to the CI
    // matrix: x86_64-linux and aarch64-macos.
    //
    // Linux returns -errno in the return register. macOS instead sets the
    // carry flag and returns errno positive, so the macOS sequences fold
    // that into a negative return (aarch64: csneg on carry; x86_64: setc
    // into a zeroed register, negate in Zig below). macOS prefixes BSD
    // numbers (write = 0x2000004) and takes the number in x16 on aarch64.
    const is_macos = builtin.os.tag == .macos;
    const sys_write = switch (builtin.cpu.arch) {
        .x86_64 => struct {
            fn call(fd: i32, buf: [*]const u8, len: usize) usize {
                if (comptime is_macos) {
                    // Carry flag holds the error bit: fold it into rax so
                    // errors come back negative like Linux (-errno).
                    // rcx/r11 are syscall-clobbered, safe as scratch.
                    return asm volatile ("xorl %ecx, %ecx\n\tsyscall\n\tsbb %rcx, %rcx\n\tmov %rax, %r11\n\tneg %r11\n\tand %rcx, %r11\n\tnot %rcx\n\tand %rcx, %rax\n\tor %r11, %rax"
                        : [ret] "={rax}" (-> usize),
                        : [nr] "{rax}" (@as(usize, 0x2000004)),
                          [fd] "{rdi}" (@as(usize, @intCast(fd))),
                          [p] "{rsi}" (@as(usize, @intFromPtr(buf))),
                          [n] "{rdx}" (len),
                        : .{ .rcx = true, .r11 = true, .memory = true }
                    );
                } else {
                    return asm volatile ("syscall"
                        : [ret] "={rax}" (-> usize),
                        : [nr] "{rax}" (@as(usize, 1)),
                          [fd] "{rdi}" (@as(usize, @intCast(fd))),
                          [p] "{rsi}" (@as(usize, @intFromPtr(buf))),
                          [n] "{rdx}" (len),
                        : .{ .rcx = true, .r11 = true, .memory = true }
                    );
                }
            }
        },
        .aarch64 => struct {
            fn call(fd: i32, buf: [*]const u8, len: usize) usize {
                if (comptime is_macos) {
                    // Number via x8, moved to x16 (macOS takes it there);
                    // csneg folds carry-flag errors into -errno.
                    return asm volatile ("mov x16, x8\n\tsvc #0x80\n\tcsneg x0, x0, x0, cs"
                        : [ret] "={x0}" (-> usize),
                        : [nr] "{x8}" (@as(usize, 0x2000004)),
                          [fd] "{x0}" (@as(usize, @intCast(fd))),
                          [p] "{x1}" (@as(usize, @intFromPtr(buf))),
                          [n] "{x2}" (len),
                        : .{ .memory = true }
                    );
                } else {
                    return asm volatile ("svc #0"
                        : [ret] "={x0}" (-> usize),
                        : [nr] "{x8}" (@as(usize, 64)),
                          [fd] "{x0}" (@as(usize, @intCast(fd))),
                          [p] "{x1}" (@as(usize, @intFromPtr(buf))),
                          [n] "{x2}" (len),
                        : .{ .memory = true }
                    );
                }
            }
        },
        else => @compileError("unsupported arch"),
    };

    const sys_read = switch (builtin.cpu.arch) {
        .x86_64 => struct {
            fn call(fd: i32, buf: [*]u8, len: usize) usize {
                if (comptime is_macos) {
                    return asm volatile ("xorl %ecx, %ecx\n\tsyscall\n\tsbb %rcx, %rcx\n\tmov %rax, %r11\n\tneg %r11\n\tand %rcx, %r11\n\tnot %rcx\n\tand %rcx, %rax\n\tor %r11, %rax"
                        : [ret] "={rax}" (-> usize),
                        : [nr] "{rax}" (@as(usize, 0x2000003)),
                          [fd] "{rdi}" (@as(usize, @intCast(fd))),
                          [p] "{rsi}" (@as(usize, @intFromPtr(buf))),
                          [n] "{rdx}" (len),
                        : .{ .rcx = true, .r11 = true, .memory = true }
                    );
                } else {
                    return asm volatile ("syscall"
                        : [ret] "={rax}" (-> usize),
                        : [nr] "{rax}" (@as(usize, 0)),
                          [fd] "{rdi}" (@as(usize, @intCast(fd))),
                          [p] "{rsi}" (@as(usize, @intFromPtr(buf))),
                          [n] "{rdx}" (len),
                        : .{ .rcx = true, .r11 = true, .memory = true }
                    );
                }
            }
        },
        .aarch64 => struct {
            fn call(fd: i32, buf: [*]u8, len: usize) usize {
                if (comptime is_macos) {
                    return asm volatile ("mov x16, x8\n\tsvc #0x80\n\tcsneg x0, x0, x0, cs"
                        : [ret] "={x0}" (-> usize),
                        : [nr] "{x8}" (@as(usize, 0x2000003)),
                          [fd] "{x0}" (@as(usize, @intCast(fd))),
                          [p] "{x1}" (@as(usize, @intFromPtr(buf))),
                          [n] "{x2}" (len),
                        : .{ .memory = true }
                    );
                } else {
                    return asm volatile ("svc #0"
                        : [ret] "={x0}" (-> usize),
                        : [nr] "{x8}" (@as(usize, 63)),
                          [fd] "{x0}" (@as(usize, @intCast(fd))),
                          [p] "{x1}" (@as(usize, @intFromPtr(buf))),
                          [n] "{x2}" (len),
                        : .{ .memory = true }
                    );
                }
            }
        },
        else => @compileError("unsupported arch"),
    };

    pub fn read(hFile: usize, buf: []u8) !usize {
        if (comptime is_macos) {
            const ret = std.c.read(@intCast(hFile), buf.ptr, buf.len);
            if (ret < 0) {
                return switch (std.c._errno().*) {
                    4 => error.WouldBlock, // EINTR
                    else => error.InputOutput,
                };
            }
            return @intCast(ret);
        }
        // Reads come from the same raw-syscall path as writes:
        // Linux returns -errno.
        const ret: isize = @bitCast(sys_read.call(@intCast(hFile), buf.ptr, buf.len));
        if (ret < 0) {
            return switch (@as(u32, @truncate(@as(u64, @bitCast(-ret))))) {
                4 => error.WouldBlock, // EINTR: caller retries
                else => error.InputOutput,
            };
        }
        return @intCast(ret);
    }

    pub fn write(hFile: usize, bytes: []const u8) !usize {
        if (comptime is_macos) {
            const ret = std.c.write(@intCast(hFile), bytes.ptr, bytes.len);
            if (ret < 0) {
                return switch (std.c._errno().*) {
                    32 => error.BrokenPipe, // EPIPE
                    else => error.InputOutput,
                };
            }
            if (ret == 0 and bytes.len > 0) return error.InputOutput;
            return @intCast(ret);
        }
        // Raw syscalls return -errno on failure.
        const ret: isize = @bitCast(sys_write.call(@intCast(hFile), bytes.ptr, bytes.len));
        if (ret < 0) {
            return switch (@as(u32, @truncate(@as(u64, @bitCast(-ret))))) {
                32 => error.BrokenPipe, // EPIPE
                else => error.InputOutput,
            };
        }
        if (ret == 0 and bytes.len > 0) return error.InputOutput; // would spin writeAll
        return @intCast(ret);
    }

    pub fn writeAll(hFile: usize, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = try write(hFile, rest);
            rest = rest[n..];
        }
    }

    pub fn isPipe(_: usize) bool {
        // Raw-syscall path has no fstat handy; only Windows uses the
        // chunked pipe transport, POSIX writes go whole. Never a pipe.
        return false;
    }
};

