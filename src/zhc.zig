const std = @import("std");
const CallingConvention = std.builtin.CallingConvention;

const builtin = @import("builtin");

pub const build = @import("build.zig");
pub const compilation = @import("compilation.zig");
pub const abi = @import("abi.zig");

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

pub fn declareKernel(comptime k: Kernel, comptime func: anytype) void {
    compilation.deviceOnly();
    @export(func, .{.name = abi.kernel_declaration_sym_prefix ++ k.name});
}

pub fn launch(comptime k: Kernel, args: anytype) void {
    compilation.hostOnly();
    const kernel_fn_ptr = @extern(*const fn() void, .{
        .name = abi.mangleKernelArrayName(k.name, @TypeOf(args)),
        .linkage = .Weak,
    });
    (kernel_fn_ptr.?)();
}

test {
    _ = abi;
}
