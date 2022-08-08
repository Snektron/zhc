const std = @import("std");
const CallingConvention = std.builtin.CallingConvention;

const builtin = @import("builtin");

/// Build-integration is exported here. When using ZHC build options,
/// it is advised to not use any functionality outside this path.
pub const build = @import("build.zig");

/// Build options and utilities for the current compilation.
pub const compilation = @import("compilation.zig");

/// The calling conventions that kernels for the current device architecture should have.
pub const kernel_cc: CallingConvention = switch (compilation.device_arch) {
    .amdgcn => .AmdgpuKernel,
    else => @compileError("Unsupported device archtecture " ++ @tagName(builtin.cpu.arch)),
};

pub const Kernel = struct {
    name: []const u8,
};

pub fn kernel(name: []const u8) Kernel {
    return .{.name = name};
}

pub inline fn declareKernel(comptime k: Kernel, comptime func: anytype) void {
    compilation.deviceOnly();
    @export(func, .{.name = "__zhc_kd_" ++ k.name});
}

pub fn launch(comptime k: Kernel) void {
    compilation.hostOnly();
    const kernel_fn_ptr = @extern(*const fn() void, .{
        .name = "__zhc_ka_" ++ k.name,
        .linkage = .Weak,
    });
    _ = kernel_fn_ptr;
}
