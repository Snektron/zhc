const std = @import("std");
const CallingConvention = std.builtin.CallingConvention;

const builtin = @import("builtin");

pub const build = @import("build.zig");
pub const compilation = @import("compilation.zig");
pub const abi = @import("abi.zig");

/// The calling convention that user-kernels should be declared to have.
/// Note: This is actually a method to prevent the compiler from analyzing the function
/// before we actually call it. This allows us to pass around the function, which
/// has device code, without it accidently being compiled on the host.
/// This also allows users to more easily spot "entry points" in their code, as opposed
/// to when the user is just told to put `inline` on the kernel function.
/// We want to call user kernels with inline from the entry point wrapper anyway.
pub const kernel_cc = CallingConvention.Inline;

/// The *actual* calling convention that exported kernel functions should have. The proper
/// value depends on the device architecture and OS.
pub const real_kernel_cc: CallingConvention = switch (compilation.device_arch) {
    .amdgcn => .AmdgpuKernel,
    .x86_64 => .C,
    else => @compileError("Unsupported device archtecture " ++ @tagName(compilation.device_arch)),
};

pub const Kernel = struct {
    name: []const u8,
};

pub fn kernel(name: []const u8) Kernel {
    return .{.name = name};
}

/// Utility function that generates a struct with an entry point for a particular kernel.
fn EntryPoint(comptime func: anytype, comptime overload: abi.Overload) type {
    // Generate the arguments struct with the arguments that the driver
    // should actually pass to the kernel. This entails all the `typed_runtime_value`s,
    // but some should be handled in a special way.
    var fields: [32]std.builtin.Type.StructField = undefined;
    var i: usize = 0;
    for (overload.args) |arg| {
        const ty = switch (arg) {
            .typed_runtime_value => |ty| ty.*,
            else => continue, // Value is known, so we can put it in the kernel call directly.
        };

        var num_buf: [128]u8 = undefined;
        // This might need to be exported into some device-specific function at some point.
        switch (ty) {
            .int, .float, .bool, .array => {
                const T = ty.ToType();
                fields[i] = .{
                    .name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable,
                    .field_type = T,
                    .default_value = null,
                    .is_comptime = false,
                    // TODO: Make sure type is never zero sized.
                    .alignment = @alignOf(T),
                };
                i += 1;
            },
            .pointer => |info| {
                // Split out slices into 2 parameters.
                const ptr_ty = switch (info.size) {
                    .slice => info.slicePtrType(),
                    else => ty,
                };
                const PtrT = ptr_ty.ToType();
                fields[i] = .{
                    .name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable,
                    .field_type = PtrT,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(PtrT),
                };
                i += 1;

                if (info.size == .slice) {
                    fields[i] = .{
                        .name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable,
                        // Note: device usize, might be different from host.
                        .field_type = usize,
                        .default_value = null,
                        .is_comptime = false,
                        .alignemnt = @alignOf(usize),
                    };
                    i += 1;
                }
            },
            else => unreachable,
        }
    }

    const Args = @Type(.{.Struct = .{
        .is_tuple = false,
        .layout = .Extern,
        .decls = &.{},
        .fields = fields[0..i],
    }});

    return struct {
        /// The real actual entry point of the kernel. Parameters
        /// are passed via a struct with known layout, which depends
        /// on the device architecture.
        // TODO: Passing via structs is not always the most efficient, so there
        //   might need to be some way to force it to pass it via registers if
        //   possible.
        pub fn deviceMain(args: Args) callconv(real_kernel_cc) void {
            _ = args;
            _ = func;
        }

        // Work around stage 2 limitation where it cant export a struct field yet.
        pub fn exportIt(comptime k: Kernel) void {
            const name = comptime abi.mangleKernelDefinitionName(k, overload);
            @export(deviceMain, .{.name = name});
        }
    };
}

/// Mark a kernel as being exported. When compiling in device mode, an entry point
/// is generated for this function for each overload passed via the compile options.
pub fn declareKernel(comptime k: Kernel, comptime func: anytype) void {
    if (!compilation.isDevice()) {
        // Don't export kernels in non-device code.
        return;
    }
    const launch_configurations = compilation.launch_configurations;
    if (!@hasDecl(launch_configurations, k.name)) {
        // User did not request this kernel to be exported, so just ignore it.
        return;
    }
    const overloads: []const abi.Overload = @field(launch_configurations, k.name);

    for (overloads) |overload| {
        EntryPoint(func, overload).exportIt(k);
    }
}

pub fn launch(comptime k: Kernel, args: anytype) void {
    compilation.hostOnly();
    const Args = @TypeOf(args);
    const name = comptime abi.mangleKernelArrayName(k, Args);
    const kernel_fn_ptr = @extern(*const fn() void, .{
        .name = name,
        .linkage = .Weak,
    });
    (kernel_fn_ptr.?)();
}

test {
    _ = abi;
}
