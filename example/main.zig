const std = @import("std");
const zhc = @import("zhc");

const kernel = @import("kernel.zig");

pub fn main() void {
    zhc.compilation.hostOnly();
    var a: u64 = 0;
    zhc.launch(kernel.test_kernel, .{ &a, a, a });
}
