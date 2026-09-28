const std = @import("std");

// Bounded MPMC work queue of path batches. The walker is the producer,
// workers are consumers. No locks: a head/tail counter pair with release
// stores gives the ordering, and every slot is written before the counter
// that publishes it.
//
// Capacity is a power of two so wrap is a mask, not a modulo.
//
// ponytail: drop-on-full is not correct for a file walker, so push spins
// instead. Bounded queue plus spinning producer is the whole point: it
// caps memory on 300k-file trees without a second allocation scheme.

pub fn Queue(comptime cap: usize) type {
    comptime {
        if (cap == 0 or (cap & (cap - 1)) != 0) @compileError("cap must be a power of two");
    }

    return struct {
        const Self = @This();
        pub const Capacity = cap;

        slots: [cap]?[]const u8 = @splat(null),
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        /// Producer side. Spins while the ring is full.
        pub fn push(self: *Self, path: []const u8) void {
            while (self.head.load(.acquire) -% self.tail.load(.acquire) == cap) {
                std.Thread.yield() catch {};
            }
            const i = self.head.load(.monotonic);
            self.slots[i & (cap - 1)] = path;
            self.head.store(i + 1, .release);
        }

        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }

        /// Consumer side. Returns null once the queue is closed and drained.
        /// MPMC-safe: exactly one consumer wins each slot via cmpxchg on
        /// tail. Losers retry instead of two workers scanning one file.
        /// Close-drain race: pop returns null only when closed AND the
        /// queue is empty at claim time. A worker that loses the last
        /// claim to a closer rechecks instead of exiting early.
        pub fn pop(self: *Self) ?[]const u8 {
            while (true) {
                const t = self.tail.load(.monotonic);
                const h = self.head.load(.acquire);
                if (t -% h == 0) {
                    if (self.closed.load(.acquire)) {
                        // Recheck: the producer may have pushed between our
                        // empty read and the closed read.
                        if (self.tail.load(.monotonic) -% self.head.load(.acquire) == 0) return null;
                        continue;
                    }
                    std.Thread.yield() catch {};
                    continue;
                }
                // Claim slot t: only the winner advances tail.
                if (self.tail.cmpxchgStrong(t, t +% 1, .acq_rel, .monotonic) != null) continue;
                const slot = self.slots[t & (cap - 1)];
                self.slots[t & (cap - 1)] = null;
                return slot;
            }
        }

        pub fn isEmpty(self: *Self) bool {
            return self.tail.load(.acquire) -% self.head.load(.acquire) == 0;
        }
    };
}

const testing = std.testing;

test "queue: push then pop in order" {
    var q = Queue(8){};
    q.push("a");
    q.push("b");
    q.close();
    try testing.expectEqualStrings("a", q.pop().?);
    try testing.expectEqualStrings("b", q.pop().?);
    try testing.expectEqual(@as(?[]const u8, null), q.pop());
}

test "queue: pop blocks until push arrives" {
    var q = Queue(4){};
    const Consumer = struct {
        queue: *Queue(4),
        got: *std.atomic.Value(usize),
        fn run(self: *@This()) void {
            const v = self.queue.pop();
            self.got.store(if (v != null) 1 else 0, .release);
        }
    };
    var got = std.atomic.Value(usize).init(0);
    var c = Consumer{ .queue = &q, .got = &got };
    var t = try std.Thread.spawn(.{}, Consumer.run, .{&c});
    // Let the consumer block on the empty queue before publishing.
    var spins: usize = 0;
    while (q.isEmpty() and spins < 1_000_000) : (spins += 1) std.Thread.yield() catch {};
    q.push("late");
    t.join();
    try testing.expectEqual(@as(usize, 1), got.load(.acquire));
}

test "queue: wraps around past capacity" {
    var q = Queue(4){};
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var name: [4]u8 = undefined;
        const n = std.fmt.bufPrint(&name, "p{d}", .{i}) catch unreachable;
        q.push(n);
        // Keep the ring from filling: pop one after each push.
        _ = q.pop();
    }
    q.close();
    try testing.expect(q.isEmpty());
}

test "queue: push/pop 200 through 64-slot ring, no loss" {
    var q = Queue(64){};
    const N = 200;
    // Push 200 through a 64-slot ring, popping as we go so the producer
    // never spins forever. Then close and drain.
    var i: usize = 0;
    var names: [N][4]u8 = undefined;
    var popped: usize = 0;
    while (i < N) : (i += 1) {
        const n = std.fmt.bufPrint(&names[i], "i{d:0>3}", .{i}) catch unreachable;
        q.push(n);
        if (q.pop()) |_| popped += 1;
    }
    q.close();
    while (q.pop()) |_| popped += 1;
    try testing.expectEqual(N, popped);
    try testing.expect(q.isEmpty());
}
