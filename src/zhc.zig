const std = @import("std");
const CallingConvention = std.builtin.CallingConvention;

const builtin = @import("builtin");

pub const build = @import("build.zig");
pub const compilation = @import("compilation.zig");
pub const abi = @import("abi.zig");
pub const util = @import("util.zig");
pub const platform = @import("platform.zig");

/// The calling convention that user-kernels should be declared to have.
///
/// Note: This is actually a method to prevent the compiler from analyzing the function
///   before we actually call it. This allows us to pass around the function, which
///   has device code, without it accidently being compiled on the host.
///   This also allows users to more easily spot "entry points" in their code, as opposed
///   to when the user is just told to put `inline` on the kernel function.
///   We want to call user kernels with inline from the entry point wrapper anyway.
pub const kernel_cc = CallingConvention.Inline;

/// The *actual* calling convention that exported kernel functions should have. The proper
/// value depends on the device architecture and OS.
pub const real_kernel_cc: CallingConvention = switch (compilation.platform) {
    .amdgpu => .AmdgpuKernel,
};

pub const Kernel = struct {
    name: []const u8,
};

pub fn kernel(name: []const u8) Kernel {
    return .{ .name = name };
}

/// Mark a kernel as being exported. When compiling in device mode, an entry point
/// is generated for this function for each overload passed via the compile options.
pub fn declareKernel(comptime k: Kernel, comptime func: anytype) void {
    if (!compilation.isDevice()) {
        // We can't export kernels in host code.
        @compileError("cannot export kernel during host compilation");
    }
    const launch_configurations = compilation.launch_configurations;
    if (!@hasDecl(launch_configurations, k.name)) {
        // User did not request this kernel to be exported, so just ignore it.
        return;
    }
    const overloads: []const abi.Overload = @field(launch_configurations, k.name);

    for (overloads) |overload| {
        abi.exportEntryPoint(k, func, overload);
    }
}

pub fn launch(comptime k: Kernel, args: anytype) void {
    compilation.hostOnly();
    const Args = @TypeOf(args);
    const name = comptime abi.mangling.mangleKernelArrayName(k, Args);
    const kernel_fn_ptr = @extern(*const fn () void, .{
        .name = name,
        .linkage = .Weak,
    });
    (kernel_fn_ptr.?)();
}

test {
    _ = abi;
}
