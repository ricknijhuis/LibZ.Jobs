const std = @import("std");
const assert = @import("assert");
const debug = std.debug;
const math = std.math;

/// FixedDeque for use in job system, allows for lockfree pushing and poping of the top by as single thread, and stealing from the bottom from other threads.
/// Size needs to be a power of 2 for optimization purposes and smaller than maxInt(i32)
pub fn FixedDeque(comptime T: type, comptime size: usize) type {
    comptime debug.assert(size > 0);
    comptime debug.assert(size < math.maxInt(i32));
    comptime debug.assert(assert.isPowerOf2(size));

    const mask: i32 = @intCast(size - 1);

    return struct {
        const Self = @This();

        buffer: [size]T,
        bottom: i32,
        top: i32,

        pub fn init() Self {
            return .{
                .buffer = undefined,
                .bottom = 0,
                .top = 0,
            };
        }

        pub fn push(self: *Self, value: T) void {
            const b = self.bottom;
            debug.assert((b - self.top) < size);
            self.buffer[@intCast(b & mask)] = value;
            self.bottom = b + 1;
        }

        pub fn pop(self: *Self) ?T {
            const b = self.bottom - 1;

            _ = @atomicRmw(i32, &self.bottom, .Xchg, b, .seq_cst);

            const t = self.top;

            if (t <= b) {
                var item: ?T = self.buffer[@intCast(b & mask)];
                if (t != b) {
                    return item;
                }
                if (@cmpxchgStrong(i32, &self.top, t, t + 1, .seq_cst, .seq_cst) != null) {
                    item = null;
                }

                self.bottom = t + 1;
                return item;
            }

            self.bottom = t;
            return null;
        }

        pub fn steal(self: *Self) ?T {
            const t = self.top;
            const b = self.bottom;
            if (t < b) {
                const item = self.buffer[@intCast(t & mask)];
                if (@cmpxchgStrong(i32, &self.top, t, t + 1, .seq_cst, .seq_cst) != null) {
                    return null;
                }
                return item;
            }
            return null;
        }

        pub fn reset(self: *Self) void {
            @atomicStore(i32, self.bottom, 0, .acq_rel);
            @atomicStore(i32, &self.top, 0, .acq_rel);
        }

        /// NOT THREAD SAFE
        pub fn len(self: *const Self) u32 {
            return @intCast(self.bottom - self.top);
        }
    };
}

test "FixedDeque: init value type" {
    const testing = std.testing;
    const deque = FixedDeque(i32, 8).init();

    try testing.expectEqual(8, deque.buffer.len);
}

test "FixedDeque: push adds items" {
    const testing = std.testing;

    const size: usize = 8;

    var deque = FixedDeque(i32, size).init();

    for (0..size) |i| {
        deque.push(@intCast(i));
    }

    for (deque.buffer, 0..size) |item, i| {
        try testing.expectEqual(@as(i32, @intCast(i)), item);
    }
}

test "FixedDeque: pop returns in LIFO" {
    const testing = std.testing;

    const size: usize = 8;

    var deque = FixedDeque(i32, size).init();

    for (0..size) |i| {
        deque.push(@intCast(i));
    }

    for (deque.buffer, 0..size) |item, i| {
        try testing.expectEqual(@as(i32, @intCast(i)), item);
    }

    var i: i32 = @intCast(size);
    i -= 1;
    while (deque.pop()) |item| : (i -= 1) {
        try testing.expectEqual(i, item);
    }
}

test "FixedDeque: steal returns in FIFO" {
    const testing = std.testing;

    const size: usize = 8;

    var deque = FixedDeque(i32, size).init();

    for (0..size) |i| {
        deque.push(@intCast(i));
    }

    for (deque.buffer, 0..size) |item, i| {
        try testing.expectEqual(@as(i32, @intCast(i)), item);
    }

    var i: i32 = 0;
    while (deque.steal()) |item| : (i += 1) {
        try testing.expectEqual(i, item);
    }
}
