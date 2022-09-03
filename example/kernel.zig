const std = @import("std");
const zhc = @import("zhc");

// Device panic handler, defined here to avoid emitting std printing functions.
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    _ = msg;
    _ = error_return_trace;
    while (true) {}
}

fn testKernel(comptime T: type, a: *T, b: anytype, doit: i32) callconv(zhc.kernel_cc) void {
    zhc.compilation.deviceOnly();
    if (doit)
        a.* = b;
}

pub const test_kernel = zhc.kernel("testKernel");

comptime {
    if (zhc.compilation.isDevice()) {
        zhc.declareKernel(test_kernel, testKernel);
    }
}
