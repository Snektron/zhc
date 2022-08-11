//! This file defines abi-utilities between the host and device
//! binaries.

const std = @import("std");
const zhc = @import("zhc.zig");

const Kernel = zhc.Kernel;

const Allocator = std.mem.Allocator;
const BigInt = std.math.big.int.Const;
const BigIntMut = std.math.big.int.Mutable;
const BigIntLimb = std.math.big.Limb;

/// "Kernel declaration" symbols have this prefix.
pub const kernel_declaration_sym_prefix = "__zhc_kd_";
/// "Kernel array" symbols have this prefix.
pub const kernel_array_sym_prefix = "__zhc_ka_";

pub const max_kernel_args = 32;

const constant_int_hex_digits_per_limb_byte = 2;

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

    pub fn mangle(self: AbiValue, writer: anytype) @TypeOf(writer).Error!void {
        switch (self) {
            .int => |info| {
                const signedness: u8 = switch (info.signedness) {
                    .signed => 'i',
                    .unsigned => 'u',
                };
                try writer.print("{c}{}", .{signedness, info.bits});
            },
            .float => |info| try writer.print("f{}", .{info.bits}),
            .bool => try writer.writeByte('b'),
            .array => |info| {
                try writer.print("a{}", .{info.len});
                try info.child.mangle(writer);
            },
            .pointer => |info| {
                const size: u8 = switch (info.size) {
                    .one => 'p',
                    .many => 'P',
                    .slice => 's',
                };
                const constness: u8 = switch (info.is_const) {
                    true => 'c',
                    false => 'm',
                };
                try writer.print("{c}{c}{}", .{size, constness, info.alignment});
                try info.child.mangle(writer);
            },
            .constant_int => |value| {
                // Write it out in hex, so that we don't need to have any additional memory.
                try writer.writeByte('I');
                try writeBigIntAsHex(writer, value);
                const sign: u8 = switch (value.positive) {
                    true => 'p',
                    false => 'n',
                };
                // Use the sign as a terminator for the value.
                try writer.writeByte(sign);
            },
            .constant_bool => |value| try writer.writeByte(if (value) 'T' else 'F'),
            .typed_runtime_value => |child| {
                try writer.writeByte('r');
                try child.mangle(writer);
            },
        }
    }

    pub const DemangleError = error {
        InvalidMangledName,
        OutOfMemory,
    };

    pub fn demangle(arena: Allocator, input: []const u8) DemangleError!AbiValue {
        var p = Parser{
            .input = input,
            .arena = arena,
        };
        return p.demangle();
    }

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
                try writeBigIntAsHex(writer, value);
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

fn writeBigIntAsHex(writer: anytype, value: BigInt) !void {
    const digits_per_limb = @sizeOf(BigIntLimb) * constant_int_hex_digits_per_limb_byte;
    const limb_padded_fmt = comptime std.fmt.comptimePrint("{{X:0>{}}}", .{digits_per_limb});

    var i: usize = value.limbs.len - 1;
    // Don't need to pad the first limb.
    try writer.print("{X}", .{value.limbs[i]});
    while (i > 0) {
        i -= 1;
        try writer.print(limb_padded_fmt, .{value.limbs[i]});
    }
}

const Parser = struct {
    input: []const u8,
    offset: usize = 0,
    arena: Allocator,

    fn peek(p: Parser) ?u8 {
        if (p.offset < p.input.len)
            return p.input[p.offset];
        return null;
    }

    fn next(p: *Parser) !u8 {
        const c = p.peek() orelse error.InvalidMangledName;
        p.offset += 1;
        return c;
    }

    fn expect(p: *Parser, expected: u8) !void {
        const actual = try p.next();
        if (actual != expected)
            return error.InvalidMangledName;
    }

    fn parseDecimal(p: *Parser, comptime T: type) !T {
        const len = for (p.input[p.offset..]) |c, i| {
            if (!std.ascii.isDigit(c))
                break i;
        } else p.input.len - p.offset;

        if (len == 0) {
            return error.InvalidMangledName;
        }

        const decimal = p.input[p.offset..][0..len];
        p.offset += len;
        return std.fmt.parseInt(T, decimal, 10) catch error.InvalidMangledName;
    }

    fn parseName(p: *Parser) ![]const u8 {
        const len = try p.parseDecimal(usize);
        try p.expect('_');
        const end = p.offset + len;
        if (len == 0 or end > p.input.len)
            return error.InvalidMangledName;
        const name = p.input[p.offset..end];
        p.offset = end;
        return name;
    }

    fn demangleAbiValue(p: *Parser) AbiValue.DemangleError!AbiValue {
        const type_byte = try p.next();
        switch (type_byte) {
            'i', 'u', 'f' => {
                const bits = try p.parseDecimal(u16);
                return switch (type_byte) {
                    'i' => AbiValue{.int = .{.signedness = .signed, .bits = bits}},
                    'u' => AbiValue{.int = .{.signedness = .unsigned, .bits = bits}},
                    'f' => AbiValue{.float = .{.bits = bits}},
                    else => unreachable,
                };
            },
            'b' => return AbiValue{.bool = {}},
            'a' => {
                const len = try p.parseDecimal(u64);
                const child = try p.arena.create(AbiValue);
                child.* = try p.demangleAbiValue();
                return AbiValue{.array = .{.len = len, .child = child}};
            },
            'p', 'P', 'S' => {
                const size: AbiValue.PointerType.Size = switch (type_byte) {
                    'p' => .one,
                    'P' => .many,
                    'S' => .slice,
                    else => unreachable,
                };
                const is_const = switch (try p.next()) {
                    'c' => true,
                    'm' => false,
                    else => return error.InvalidMangledName,
                };
                const alignment = try p.parseDecimal(u16);
                const child = try p.arena.create(AbiValue);
                child.* = try p.demangleAbiValue();
                return AbiValue{
                    .pointer = .{
                        .size = size,
                        .is_const = is_const,
                        .alignment = alignment,
                        .child = child,
                    },
                };
            },
            'I' => return AbiValue{.constant_int = try p.demangleConstantInt()},
            'T' => return AbiValue{.constant_bool = true},
            'F' => return AbiValue{.constant_bool = false},
            'r' => {
                const child = try p.arena.create(AbiValue);
                child.* = try p.demangleAbiValue();
                return AbiValue{.typed_runtime_value = child};
            },
            else => return error.InvalidMangledName,
        }
    }

    fn demangleKernelConfig(p: *Parser) !KernelConfig {
        const name = try p.parseName();
        const num_args = try p.parseDecimal(usize);
        const args = try p.arena.alloc(AbiValue, num_args);
        for (args) |*arg| {
            arg.* = try p.demangleAbiValue();
        }
        return KernelConfig{
            .kernel = .{.name = try p.arena.dupe(u8, name)},
            .overload = .{.args = args},
        };
    }

    fn demangleConstantInt(p: *Parser) !BigInt {
        const len = for (p.input[p.offset..]) |c, i| {
            switch (c) {
                'p', 'n' => break i,
                else => {},
            }
        } else return error.InvalidMangledName;

        if (len == 0) {
            return error.InvalidMangledName;
        }

        const positive = switch (p.input[p.offset + len]) {
            'p' => true,
            'n' => false,
            else => unreachable,
        };

        const digits = p.input[p.offset..][0..len];
        const digits_per_limb = @sizeOf(BigIntLimb) * constant_int_hex_digits_per_limb_byte;

        const num_limbs = std.math.divCeil(usize, len, digits_per_limb) catch unreachable;
        const limbs = try p.arena.alloc(BigIntLimb, num_limbs);

        for (limbs) |*limb, i| {
            const rend = i * digits_per_limb;
            const rstart = @minimum(rend + digits_per_limb, digits.len);
            const limb_digits = digits[digits.len - rstart .. digits.len - rend];
            limb.* = std.fmt.parseInt(BigIntLimb, limb_digits, 16) catch return error.InvalidMangledName;
        }

        p.offset += len + 1;
        var mut = BigIntMut{
            .limbs = limbs,
            .len = limbs.len,
            .positive = positive,
        };
        mut.normalize(limbs.len);
        if (mut.eqZero()) {
            mut.positive = true;
        }
        return mut.toConst();
    }
};

fn testMangle(expected: []const u8, abi_type: AbiValue) !void {
    var al = std.ArrayList(u8).init(std.testing.allocator);
    defer al.deinit();
    try abi_type.mangle(al.writer());
    try std.testing.expectEqualSlices(u8, expected, al.items);
}

fn testMangleInt(expected: []const u8, int: anytype) !void {
    var value = try std.math.big.int.Managed.initSet(std.testing.allocator, int);
    defer value.deinit();
    const abi_ci = .{.constant_int = value.toConst()};
    try testMangle(expected, abi_ci);
}

test "AbiValue - mangle" {
    try testMangle("u8", .{.int = .{.signedness = .unsigned, .bits = 8}});
    try testMangle("f16", .{.float = .{.bits = 16}});
    const abi_i32 = .{.int = .{.signedness = .signed, .bits = 32}};
    try testMangle("i32", abi_i32);
    const abi_a5i32 = .{.array = .{.len = 5, .child = &abi_i32}};
    try testMangle("a5i32", abi_a5i32);
    const abi_pa5i32 = .{.pointer = .{.size = .one, .is_const = true, .alignment = 4, .child = &abi_a5i32}};
    try testMangle("pc4a5i32", abi_pa5i32);

    try testMangleInt("I1234ABCDp", 0x1234ABCD);
    try testMangleInt("I111122223333444455556666777n", -0x111122223333444455556666777);
    try testMangleInt("I0p", 0x0);
    try testMangleInt("I10000000000000000p", 0x10000000000000000);

    try testMangle("T", .{.constant_bool = true});
}

fn testDemangle(expected: AbiValue, mangled: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser{
        .input = mangled,
        .arena = arena.allocator(),
    };
    const actual = try p.demangleAbiValue();
    try std.testing.expectEqual(mangled.len, p.offset);
    try std.testing.expect(AbiValue.eql(expected, actual));
}

fn testDemangleInt(expected: anytype, mangled: []const u8) !void {
    var value = try std.math.big.int.Managed.initSet(std.testing.allocator, expected);
    defer value.deinit();
    const abi_ci = .{.constant_int = value.toConst()};
    try testDemangle(abi_ci, mangled);
}

test "AbiValue - demangle" {
    try testDemangle(.{.int = .{.signedness = .unsigned, .bits = 32}}, "u32");
    try testDemangle(.{.float = .{.bits = 64}}, "f64");
    const abi_i16 = .{.int = .{.signedness = .signed, .bits = 16}};
    try testDemangle(abi_i16, "i16");
    const abi_a987i16 = .{.array = .{.len = 987, .child = &abi_i16}};
    try testDemangle(abi_a987i16, "a987i16");
    const abi_pa987i16 = .{.pointer = .{.size = .slice, .is_const = false, .alignment = 123, .child = &abi_a987i16}};
    try testDemangle(abi_pa987i16, "Sm123a987i16");

    try testDemangleInt(0x11223344, "I11223344p");
    try testDemangleInt(-0xAAAABBBBCCCCDDDDEEEEF, "IAAAABBBBCCCCDDDDEEEEFn");
    try testDemangleInt(0x0, "I00000000000000000000000000000n");

    try testDemangle(.{.constant_bool = false}, "F");
}

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

        return .{.args = &abi_args};
    }

    fn valueToAbiValue(comptime T: type, comptime value: T) AbiValue {
        return switch (@typeInfo(T)) {
            .Type => typeToAbiValue(value),
            .Int, .ComptimeInt => blk: {
                const num_limbs = std.math.big.int.calcLimbLen(value);
                var limbs: [num_limbs]BigIntLimb = undefined;
                const big_int = BigIntMut.init(&limbs, value).toConst();
                break :blk .{.constant_int = big_int};
            },
            .Bool => .{.constant_bool = value},
            else => @compileError("unsupported zhc abi value of type " ++ @typeName(T)),
        };
    }

    fn typeToAbiValue(comptime T: type) AbiValue {
        return switch (@typeInfo(T)) {
            .Int => |info| .{.int = .{
                .signedness = info.signedness,
                .bits = info.bits,
            }},
            .Float => |info| .{.float = .{.bits = info.bits}},
            .Bool => .bool,
            .Array => |info| blk: {
                if (info.sentinel != 0) {
                    @compileError("unsupported zhc abi type " ++ @typeName(T));
                }
                const child = typeToAbiValue(info.child);
                break :blk .{.array = .{
                     .len = info.len,
                     .child = &child,
                }};
            },
            .Pointer => |info| blk: {
                if (info.is_volatile or info.is_allowzero or info.sentinel != null) {
                    @compileError("unsupported zhc abi type " ++ @typeName(T));
                }

                const child = typeToAbiValue(info.child);
                break :blk .{.pointer = .{
                    .is_const = info.is_const,
                    .alignment = info.alignment,
                    .size = switch (info.size) {
                        .One => .one,
                        .Many => .many,
                        .Slice => .slice,
                        .C => @compileError("unsupported zhc abi type " ++ @typeName(T)),
                    },
                    .child = &child,
                }};
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

        return KernelConfig {
            .kernel = kernel,
            .overload = Overload.init(Args),
        };
    }

    pub fn mangle(self: KernelConfig, writer: anytype) !void {
        try writer.print("{}_{s}{}", .{
            self.kernel.name.len,
            self.kernel.name,
            self.overload.args.len,
        });
        for (self.overload.args) |arg| {
            try arg.mangle(writer);
        }
    }

    pub fn demangle(arena: Allocator, input: []const u8) !KernelConfig {
        var p = Parser{
            .input = input,
            .arena = arena,
        };
        return try p.demangleKernelConfig();
    }

    /// Prints a debug representation of the KernelConfig.
    pub fn format(
        self: KernelConfig,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}({}}", .{self.kernel.name, self.overload});
    }
};

fn mangleKernelConfigFormatter(
    config: KernelConfig,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    try config.mangle(writer);
}

const MangleKernelConfigFormatter = std.fmt.Formatter(mangleKernelConfigFormatter);

pub fn mangleKernelArrayName(comptime k: Kernel, comptime Args: type) []const u8 {
    const config = KernelConfig.init(k, Args);
    return std.fmt.comptimePrint("{s}{}", .{kernel_array_sym_prefix, MangleKernelConfigFormatter{.data = config}});
}
