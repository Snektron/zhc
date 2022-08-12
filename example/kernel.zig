const std = @import("std");
const zhc = @import("zhc");

// Device panic handler, defined here to avoid emitting std printing functions.
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    _ = msg;
    _ = error_return_trace;
    while (true) {}
}

fn testKernel(a: *i32) callconv(zhc.kernel_cc) void {
    zhc.compilation.deviceOnly();
    a.* = 123;
}

pub const test_kernel = zhc.kernel("testKernel");

comptime {
    zhc.declareKernel(test_kernel, testKernel);
}
