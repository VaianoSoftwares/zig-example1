const std = @import("std");
const mem = std.mem;

pub fn array(comptime T: type, comptime size: usize, items: ?[]const T) [size]T {
    var output = mem.zeroes([size]T);
    if (items) |slice| mem.copy(T, &output, slice);
    return output;
}