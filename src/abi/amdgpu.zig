//! This file defines abi interface utilities for communication between host and device,
//! the specific parts that relate to AMDGPU.

const std = @import("std");
const zhc = @import("../zhc.zig");
const abi = zhc.abi;

const Kernel = zhc.Kernel;
const Overload = abi.Overload;

pub const kernel_cc = std.builtin.CallingConvention.AmdgpuKernel;

fn mkField(comptime index: usize, comptime T: type) std.builtin.Type.StructField {
    var name_buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}", .{index}) catch unreachable;
    return .{
        .name = name,
        .field_type = T,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf(T),
    };
}

fn RuntimeArgsStruct(comptime overload: Overload) type {
    var fields: [abi.max_kernel_args * 2]std.builtin.Type.StructField = undefined;
    var i: usize = 0;
    for (overload.args) |arg| {
        const ty = switch (arg) {
            .typed_runtime_value => |ty| ty.*,
            else => continue,
        };

        const is_slice = switch (ty) {
            .pointer => |info| info.size == .slice,
            else => false,
        };

        if (is_slice) {
            // Split out slices into 2 arguments.
            fields[i] = mkField(i, ty.slicePtrType().ToType());
            // Note: device usize. Maybe this needs a better definition than just 'usize',
            //   so that it can be made more portable across host/device.
            fields[i] = mkField(i, usize);
        } else {
            fields[i] = mkField(i, ty.ToType());
            i += 1;
        }
    }

    return @Type(.{ .Struct = .{
        .is_tuple = false,
        .layout = .Extern,
        .decls = &.{},
        .fields = fields[0..i],
    } });
}

fn EntryPoint(comptime func: anytype, comptime overload: Overload) type {
    const KernelFuncType = @TypeOf(func);
    const func_info = switch (@typeInfo(KernelFuncType)) {
        .Fn => |info| info,
        else => @compileError("Kernel must be a function"),
    };

    if (func_info.is_var_args) {
        @compileError("Kernel function cannot be variadic");
    } else if (func_info.calling_convention != zhc.kernel_cc) {
        @compileError("Kernel function must have zhc.kernel_cc calling convention");
    }

    const RuntimeArgs = RuntimeArgsStruct(overload);
    const runtime_arg_fields = @typeInfo(RuntimeArgs).Struct.fields;

    return struct {
        fn convertArgsAndCallKernel(
            runtime_args: RuntimeArgs,
            comptime runtime_index: usize,
            comptime overload_index: usize,
            kernel_args: anytype,
        ) void {
            if (overload_index == overload.args.len) {
                @call( // if you see a compile error here it means your kernel arguments are invalid
                    .{ .modifier = .always_inline }, func, kernel_args);
                return;
            }

            const arg = overload.args[overload_index];
            comptime var new_runtime_index = runtime_index;
            const value = switch (arg) {
                .typed_runtime_value => |ty| blk: {
                    const is_slice = switch (ty.*) {
                        .pointer => |info| info.size == .slice,
                        else => false,
                    };
                    if (is_slice) {
                        var slice: ty.ToType() = undefined;
                        slice.ptr = @field(runtime_args, runtime_arg_fields[runtime_index].name);
                        slice.len = @field(runtime_args, runtime_arg_fields[runtime_index + 1].name);
                        defer new_runtime_index += 2;
                        break :blk slice;
                    } else {
                        defer new_runtime_index += 1;
                        break :blk @field(runtime_args, runtime_arg_fields[runtime_index].name);
                    }
                },
                .constant_int => unreachable, // TODO: Convert big int to comptime int.
                .constant_bool => |value| value,
                else => arg.ToType(),
            };
            convertArgsAndCallKernel(runtime_args, new_runtime_index, overload_index + 1, kernel_args ++ .{value});
        }

        fn entryPoint(runtime_args: RuntimeArgs) callconv(kernel_cc) void {
            convertArgsAndCallKernel(runtime_args, 0, 0, .{});
        }

        fn declare(comptime kernel: Kernel) void {
            const name = abi.mangling.mangleKernelDefinitionName(kernel, overload);
            @export(entryPoint, .{ .name = name });
        }
    };
}

pub fn exportEntryPoint(comptime kernel: Kernel, comptime func: anytype, comptime overload: Overload) void {
    EntryPoint(func, overload).declare(kernel);
}
