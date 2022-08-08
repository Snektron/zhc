const zhc = @import("zhc");

fn testKernel(a: *i32) callconv(zhc.kernel_cc) void {
    zhc.compilation.deviceOnly();
    a.* = 123;
}

pub const test_kernel = zhc.kernel("testKernel");

comptime {
    if (zhc.compilation.isDevice()) {
        zhc.declareKernel(test_kernel, testKernel);
    }
}
