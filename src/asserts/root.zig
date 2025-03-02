const std = @import("std");
const debug = std.debug;

/// Checks if value is power of 2, requires integers of unsigned type
pub fn isPowerOf2(val: anytype) bool {
    const T = @TypeOf(val);
    comptime debug.assert(@typeInfo(T) == .int and @typeInfo(T).int.signedness == .unsigned);
    // const abs = if (@typeInfo(T) == .int and @typeInfo(T).int.signedness == .signed) math.abs(val) else val;
    return val != 0 and (val & (val - 1)) == 0;
}

test "isPowerOf2 returns true for values that are power of 2" {
    const testing = std.testing;

    const value: u32 = 0;
    const value1: u8 = 4;
    const value2: usize = 8;
    const value3: u64 = 13;

    try testing.expectEqual(false, isPowerOf2(value));
    try testing.expectEqual(true, isPowerOf2(value1));
    try testing.expectEqual(true, isPowerOf2(value2));
    try testing.expectEqual(false, isPowerOf2(value3));
}
