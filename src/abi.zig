//! This file defines abi-utilities between the host and device
//! binaries.

const std = @import("std");
const builtin = @import("builtin");
const zhc = @import("zhc.zig");

const Allocator = std.mem.Allocator;
const BigInt = std.math.big.int.Const;
const BigIntMut = std.math.big.int.Mutable;
const BigIntLimb = std.math.big.Limb;

const Kernel = zhc.Kernel;

pub const mangling = @import("abi/mangling.zig");
pub const amdgpu = @import("abi/amdgpu.zig");

/// Platform-specific ABI functions for the current platform.
/// TODO: Should this switch be done using the CPU arch? Perhaps a "platform" notion should be
///   introduced.
const native = switch (builtin.cpu.arch) {
    .amdgcn => amdgpu,
    else => @compileError("Unsupported device archtecture " ++ @tagName(builtin.cpu.arch)),
};

pub const exportEntryPoint = native.exportEntryPoint;

/// The maximum number of kernel arguments supported (for now).
pub const max_kernel_args = 32;

/// Description of structure and layout of kernel arguments. This structure can describe
/// all kernel arguments possible, but not all instances of this structure are valid.
/// Types can be categorized in two kinds:
/// - Those which are ABI-compatible, and whose instances may be passed from host
///   to device and vice versa without changing memory layout. These instances may
///   be passed indirectly - via pointers.
/// - Those which are not ABI-compatible. These types can only be passed in ways in
///   which they can be rewritten before they are passed to the device: As direct
///   values passed to the kernel.
/// Note that kernel arguments can also be comptime-known values. This is particularly
/// the case for generic kernels or kernel with comptime arguments.
/// For this reason this structure makes a distinction between the following variants
/// for direct values:
/// - Runtime values of a particular type.
/// - Comptime values, either an implicitly typed value (like `constant_int`) or a type
///   itself.
pub const AbiValue = union(enum) {
    /// Integer type. ABI-safe, depending on number of bits.
    int: IntType,
    /// Float type. ABI-safe, depending on number of bits.
    float: FloatType,
    /// Boolean type. ABI-safe.
    bool,
    /// Array type of values. ABI-safe if child is ABI-safe.
    array: ArrayType,
    /// Pointer type. Pointers may be differently sized on host and
    /// device, so this type is not ABI-safe.
    pointer: PointerType,

    /// A comptime known integer value. While the host version of this value may have
    /// a type (like `@as(u64, 123)`), all are treated as `comptime_int` here.
    constant_int: BigInt,
    /// A comptime known boolean value.
    constant_bool: bool,

    /// A runtime-value, which has this type.
    /// The child must be a type.
    typed_runtime_value: *const AbiValue,

    // TODO: More compile-time values. Floats, arrays,
    //   instances of user-defined types, etc.
    // TODO: More compile-time types. These may take pretty much any form. Even device-
    //   incompatible types are fine, as long as the user doesn't instantiate them...
    // TODO: Runtime user defined types (enum, extern struct, etc).
    //   These are all a little tricky because they either require
    //   the library to figure out a unique way of identifying types across the
    //   host and device compilations, or require structural typing.

    pub const IntType = struct {
        signedness: std.builtin.Signedness,
        // TODO: This probably needs to be limited to some subset that reliably has the same
        //   layout on host and device. Also to be considered here is the side and layout
        //   of backing types, etc.
        bits: u16,
    };

    pub const FloatType = struct {
        // TODO: Similar as int, probably limit it to 16/32/64 bits or something.
        bits: u16,
    };

    pub const ArrayType = struct {
        len: u64,
        child: *const AbiValue,
        // TODO: Sentineled array?
    };

    pub const PointerType = struct {
        size: Size,
        is_const: bool,
        alignment: u16,
        child: *const AbiValue,

        pub const Size = enum {
            one,
            many,
            /// Slices are actually structs of a pointer and a size. The latter is an
            /// usize on host, which might not neccesarily be the same size as on the
            /// device. Because kernel arguments are passed as value, however, we can
            /// rewrite this to have the proper size type when passing it over to the
            /// device.
            slice,
        };
    };

    /// Check whether two abi-value descriptions are the same.
    pub fn eql(a: AbiValue, b: AbiValue) bool {
        const tag = std.meta.activeTag(a);
        if (tag != b)
            return false;

        return switch (tag) {
            .int => std.meta.eql(a.int, b.int),
            .float => std.meta.eql(a.float, b.float),
            .bool => true,
            .array => {
                if (a.array.len != b.array.len)
                    return false;
                return a.array.child.eql(b.array.child.*);
            },
            .pointer => blk: {
                const a_info = a.pointer;
                const b_info = b.pointer;
                if (a_info.size != b_info.size)
                    break :blk false;
                if (a_info.is_const != b_info.is_const)
                    break :blk false;
                if (a_info.alignment != b_info.alignment)
                    break :blk false;
                return eql(a_info.child.*, b_info.child.*);
            },
            .constant_int => a.constant_int.eq(b.constant_int),
            .constant_bool => a.constant_bool == b.constant_bool,
            .typed_runtime_value => a.typed_runtime_value.eql(b.typed_runtime_value.*),
        };
    }

    /// Return whether this abi-value describes a type.
    pub fn isType(self: AbiValue) bool {
        return switch (self) {
            .int, .float, .bool, .array, .pointer => true,
            else => false,
        };
    }

    /// Return whether an instance of this abi-value type can be passed indirectly,
    /// that is, without modifying its memory layout.
    pub fn canBePassedIndirectly(self: AbiValue) bool {
        return switch (self) {
            .int, .float, .bool, .array => true,
            else => false,
        };
    }

    /// Return a Type version of this AbiValue. Asserts that it represents a type.
    pub fn ToType(comptime self: AbiValue) type {
        return switch (self) {
            .int => |info| @Type(.{ .Int = .{ .signedness = info.signedness, .bits = info.bits } }),
            .float => |info| @Type(.{ .Float = .{ .bits = info.bits } }),
            .bool => bool,
            .array => |info| [info.len]info.child.ToType(),
            .pointer => |info| @Type(.{
                .Pointer = .{
                    .size = switch (info.size) {
                        .one => .One,
                        .many => .Many,
                        .slice => .Slice,
                    },
                    .is_volatile = false,
                    .is_const = info.is_const,
                    .alignment = info.alignment,
                    // TODO: device kernels could require special address spaces here.
                    .address_space = .generic,
                    .child = info.child.ToType(),
                    .is_allowzero = false,
                    .sentinel = null,
                },
            }),
            else => @compileError("AbiValue is not a type"),
        };
    }

    /// Return the ManyPtr representing the pointer part of a slice.
    /// Asserts that the type is a pointer.
    pub fn slicePtrType(self: AbiValue) AbiValue {
        const info = self.pointer;
        return .{
            .size = .many,
            .is_const = info.is_const,
            .alignment = info.alignment,
            .child = info.child,
        };
    }

    pub const mangle = mangling.mangleAbiValue;
    pub const demangle = mangling.demangleAbiValue;

    /// Prints a debug representation of the AbiValue.
    pub fn format(
        self: AbiValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        switch (self) {
            .int, .float => try self.mangle(writer),
            .bool => try writer.writeAll("bool"),
            .array => |info| {
                try writer.print("[{}]", .{info.len});
                try info.child.format(fmt, options, writer);
            },
            .pointer => |info| {
                switch (info.size) {
                    .one => try writer.writeAll("*"),
                    .many => try writer.writeAll("[*]"),
                    .slice => try writer.writeAll("[]"),
                }

                if (info.is_const) {
                    try writer.writeAll("const ");
                }

                try writer.print("align({}) ", .{info.alignment});
                try info.child.format(fmt, options, writer);
            },
            .constant_int => |value| try writer.print("{}", .{value}),
            .constant_bool => |value| {
                if (value) {
                    try writer.writeAll("true");
                } else {
                    try writer.writeAll("false");
                }
            },
            .typed_runtime_value => |ty| try writer.print("(runtime value of type {})", .{ty}),
        }
    }

    pub fn toStaticInitializer(self: AbiValue, writer: anytype) @TypeOf(writer).Error!void {
        switch (self) {
            .int => |info| try writer.print(".{{.int = .{{.signedness = .{s}, .bits = {}}}}}", .{ @tagName(info.signedness), info.bits }),
            .float => |info| try writer.print(".{{.float = .{{.bits = {}}}}}", .{info.bits}),
            .bool => try writer.writeAll(".bool"),
            .array => |info| {
                try writer.print(".{{.array = .{{.len = {}, .child = &", .{info.len});
                try info.child.toStaticInitializer(writer);
                try writer.writeAll("}}");
            },
            .pointer => |info| {
                try writer.print(".{{.pointer = .{{.size = .{s}, .is_const = {}, .alignment = {}, .child = &", .{
                    @tagName(info.size),
                    info.is_const,
                    info.alignment,
                });

                try info.child.toStaticInitializer(writer);
                try writer.writeAll("}}");
            },
            .constant_int => |value| {
                try writer.writeAll(".{.constant_int = ");
                if (!value.positive) {
                    try writer.writeByte('-');
                }
                try writer.writeAll("0x");
                try mangling.writeBigIntAsHex(writer, value);
                try writer.writeByte('}');
            },
            .constant_bool => |value| {
                try writer.print(".{{.constant_bool = {}}}", .{value});
            },
            .typed_runtime_value => |child| {
                try writer.writeAll(".{.typed_runtime_value = &");
                try child.toStaticInitializer(writer);
                try writer.writeByte('}');
            },
        }
    }
};

/// Representation of a set of arguments passed to a kernel.
pub const Overload = struct {
    args: []const AbiValue,

    pub const Map = std.StringArrayHashMapUnmanaged([]const Overload);

    pub fn init(comptime Args: type) Overload {
        const args_info = @typeInfo(Args);
        if (args_info != .Struct or !args_info.Struct.is_tuple) {
            @compileError("expected tuple, found " ++ @typeName(Args));
        }

        const fields = args_info.Struct.fields;
        if (fields.len > max_kernel_args) {
            @compileError("too many arguments in kernel call");
        }

        // TODO: Validate these.
        comptime var abi_args: [fields.len]AbiValue = undefined;
        inline for (fields) |field, i| {
            if (field.is_comptime and field.default_value != null) {
                const value = @ptrCast(*const field.field_type, field.default_value.?).*;
                abi_args[i] = valueToAbiValue(field.field_type, value);
            } else {
                const runtime_value_type = typeToAbiValue(field.field_type);
                abi_args[i] = .{
                    .typed_runtime_value = &runtime_value_type,
                };
            }
        }

        return .{ .args = &abi_args };
    }

    fn valueToAbiValue(comptime T: type, comptime value: T) AbiValue {
        return switch (@typeInfo(T)) {
            .Type => typeToAbiValue(value),
            .Int, .ComptimeInt => blk: {
                const num_limbs = std.math.big.int.calcLimbLen(value);
                var limbs: [num_limbs]BigIntLimb = undefined;
                const big_int = BigIntMut.init(&limbs, value).toConst();
                break :blk .{ .constant_int = big_int };
            },
            .Bool => .{ .constant_bool = value },
            else => @compileError("unsupported zhc abi value of type " ++ @typeName(T)),
        };
    }

    fn typeToAbiValue(comptime T: type) AbiValue {
        return switch (@typeInfo(T)) {
            .Int => |info| .{ .int = .{
                .signedness = info.signedness,
                .bits = info.bits,
            } },
            .Float => |info| .{ .float = .{ .bits = info.bits } },
            .Bool => .bool,
            .Array => |info| blk: {
                if (info.sentinel != 0) {
                    @compileError("unsupported zhc abi type " ++ @typeName(T));
                }
                const child = typeToAbiValue(info.child);
                break :blk .{ .array = .{
                    .len = info.len,
                    .child = &child,
                } };
            },
            .Pointer => |info| blk: {
                if (info.is_volatile or info.is_allowzero or info.sentinel != null) {
                    @compileError("unsupported zhc abi type " ++ @typeName(T));
                }

                const child = typeToAbiValue(info.child);
                break :blk .{ .pointer = .{
                    .is_const = info.is_const,
                    .alignment = info.alignment,
                    .size = switch (info.size) {
                        .One => .one,
                        .Many => .many,
                        .Slice => .slice,
                        .C => @compileError("unsupported zhc abi type " ++ @typeName(T)),
                    },
                    .child = &child,
                } };
            },
            else => @compileError("unsupported zhc abi type " ++ @typeName(T)),
        };
    }

    /// Prints a debug representation of the Overload.
    pub fn format(
        self: Overload,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        for (self.args) |arg, i| {
            if (i != 0)
                try writer.writeAll(", ");
            try writer.print("{}", .{arg});
        }
    }

    pub fn toStaticInitializer(self: Overload, writer: anytype) !void {
        try writer.writeAll(".{.args = &.{");
        for (self.args) |arg, i| {
            if (i != 0) {
                try writer.writeAll(", ");
            }
            try arg.toStaticInitializer(writer);
        }
        try writer.writeAll("}}");
    }
};

/// Representation of an instance of a kernel.
pub const KernelConfig = struct {
    /// The kernel to which this configuration applies (the "launched" kernel).
    kernel: Kernel,
    /// Arguments with which it is launched. Note, this only contains the comptime-known
    /// parts. See `AbiValue`.
    overload: Overload,

    pub fn init(kernel: Kernel, comptime Args: type) KernelConfig {
        return KernelConfig{
            .kernel = kernel,
            .overload = Overload.init(Args),
        };
    }

    pub const mangle = mangling.mangleKernelConfig;
    pub const demangle = mangling.demangleKernelConfig;

    /// Prints a debug representation of the KernelConfig.
    pub fn format(
        self: KernelConfig,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}({}}", .{ self.kernel.name, self.overload });
    }
};

test {
    _ = mangling;
}
