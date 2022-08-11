const std = @import("std");
const zhc = @import("zhc");

const kernel = @import("kernel.zig");

pub fn main() void {
    zhc.compilation.hostOnly();
    var a: i32 = 0;
    zhc.launch(kernel.test_kernel, .{i64, &a, a, -123, true});
}
