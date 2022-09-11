const std = @import("std");
const zhc = @import("zhc");

const kernel = @import("kernel.zig");

pub fn main() void {
    zhc.compilation.hostOnly();
    var a: i64 = 1;
    var b: i32 = 2;
    var c: i16 = 3;
    zhc.launch(kernel.test_kernel, .{ i64, &a, b, c });
}
