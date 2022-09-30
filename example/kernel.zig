const std = @import("std");
const zhc = @import("zhc");

// Device panic handler, defined here to avoid emitting std printing functions.
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = return_address;
    while (true) {}
}

fn testKernel(a: *u64, b: u64, c: u64) callconv(zhc.kernel_cc) void {
    zhc.compilation.deviceOnly();
    a.* = b / c;
}

pub const test_kernel = zhc.kernel("testKernel");

comptime {
    if (zhc.compilation.isDevice()) {
        zhc.declareKernel(test_kernel, testKernel);
    }
}
