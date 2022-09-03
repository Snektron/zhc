//! This file contains functionality uses to mangle- and demangle kernel symbols.
//! Mangling is mainly for communicating the (required) kernel overloads between the host- and device
//! compilation, and is independent of the host- or device target.

const std = @import("std");
const zhc = @import("../zhc.zig");

const Allocator = std.mem.Allocator;
const BigInt = std.math.big.int.Const;
const BigIntMut = std.math.big.int.Mutable;
const BigIntLimb = std.math.big.Limb;

const Kernel = zhc.Kernel;
const AbiValue = zhc.abi.AbiValue;
const Overload = zhc.abi.Overload;
const KernelConfig = zhc.abi.KernelConfig;

/// "Kernel declaration" symbols have this prefix.
pub const kernel_declaration_sym_prefix = "__zhc_kd_";
/// "Kernel array" symbols have this prefix.
pub const kernel_array_sym_prefix = "__zhc_ka_";

const constant_int_hex_digits_per_limb_byte = 2;

pub const DemangleError = error{
    InvalidMangledName,
    OutOfMemory,
};

pub fn mangleAbiValue(value: AbiValue, writer: anytype) @TypeOf(writer).Error!void {
    switch (value) {
        .int => |info| {
            const signedness: u8 = switch (info.signedness) {
                .signed => 'i',
                .unsigned => 'u',
            };
            try writer.print("{c}{}", .{ signedness, info.bits });
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
            try writer.print("{c}{c}{}", .{ size, constness, info.alignment });
            try info.child.mangle(writer);
        },
        .constant_int => |int_value| {
            // Write it out in hex, so that we don't need to have any additional memory.
            try writer.writeByte('I');
            try writeBigIntAsHex(writer, int_value);
            const sign: u8 = switch (int_value.positive) {
                true => 'p',
                false => 'n',
            };
            // Use the sign as a terminator for the value.
            try writer.writeByte(sign);
        },
        .constant_bool => |bool_value| try writer.writeByte(if (bool_value) 'T' else 'F'),
        .typed_runtime_value => |child| {
            try writer.writeByte('r');
            try child.mangle(writer);
        },
    }
}

pub fn demangleAbiValue(arena: Allocator, input: []const u8) DemangleError!AbiValue {
    var p = Parser{
        .input = input,
        .arena = arena,
    };
    return p.demangleAbiValue();
}

pub fn mangleKernelConfig(kernel_config: KernelConfig, writer: anytype) !void {
    try writer.print("{}_{s}{}", .{
        kernel_config.kernel.name.len,
        kernel_config.kernel.name,
        kernel_config.overload.args.len,
    });
    for (kernel_config.overload.args) |arg| {
        try arg.mangle(writer);
    }
}

pub fn demangleKernelConfig(arena: Allocator, input: []const u8) DemangleError!KernelConfig {
    var p = Parser{
        .input = input,
        .arena = arena,
    };
    return try p.demangleKernelConfig();
}

pub fn writeBigIntAsHex(writer: anytype, value: BigInt) !void {
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

    fn demangleAbiValue(p: *Parser) !AbiValue {
        const type_byte = try p.next();
        switch (type_byte) {
            'i', 'u', 'f' => {
                const bits = try p.parseDecimal(u16);
                return switch (type_byte) {
                    'i' => AbiValue{ .int = .{ .signedness = .signed, .bits = bits } },
                    'u' => AbiValue{ .int = .{ .signedness = .unsigned, .bits = bits } },
                    'f' => AbiValue{ .float = .{ .bits = bits } },
                    else => unreachable,
                };
            },
            'b' => return AbiValue{ .bool = {} },
            'a' => {
                const len = try p.parseDecimal(u64);
                const child = try p.arena.create(AbiValue);
                child.* = try p.demangleAbiValue();
                return AbiValue{ .array = .{ .len = len, .child = child } };
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
            'I' => return AbiValue{ .constant_int = try p.demangleConstantInt() },
            'T' => return AbiValue{ .constant_bool = true },
            'F' => return AbiValue{ .constant_bool = false },
            'r' => {
                const child = try p.arena.create(AbiValue);
                child.* = try p.demangleAbiValue();
                return AbiValue{ .typed_runtime_value = child };
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
            .kernel = .{ .name = try p.arena.dupe(u8, name) },
            .overload = .{ .args = args },
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
    return std.fmt.comptimePrint("{s}{}", .{ kernel_array_sym_prefix, MangleKernelConfigFormatter{ .data = config } });
}

pub fn mangleKernelDefinitionName(comptime k: Kernel, comptime overload: Overload) []const u8 {
    const config = KernelConfig{
        .kernel = k,
        .overload = overload,
    };
    return std.fmt.comptimePrint("{s}{}", .{ kernel_declaration_sym_prefix, MangleKernelConfigFormatter{ .data = config } });
}

fn testMangle(expected: []const u8, abi_type: AbiValue) !void {
    var al = std.ArrayList(u8).init(std.testing.allocator);
    defer al.deinit();
    try abi_type.mangle(al.writer());
    try std.testing.expectEqualSlices(u8, expected, al.items);
}

fn testMangleInt(expected: []const u8, int: anytype) !void {
    var value = try std.math.big.int.Managed.initSet(std.testing.allocator, int);
    defer value.deinit();
    const abi_ci = .{ .constant_int = value.toConst() };
    try testMangle(expected, abi_ci);
}

test "AbiValue - mangle" {
    try testMangle("u8", .{ .int = .{ .signedness = .unsigned, .bits = 8 } });
    try testMangle("f16", .{ .float = .{ .bits = 16 } });
    const abi_i32 = .{ .int = .{ .signedness = .signed, .bits = 32 } };
    try testMangle("i32", abi_i32);
    const abi_a5i32 = .{ .array = .{ .len = 5, .child = &abi_i32 } };
    try testMangle("a5i32", abi_a5i32);
    const abi_pa5i32 = .{ .pointer = .{ .size = .one, .is_const = true, .alignment = 4, .child = &abi_a5i32 } };
    try testMangle("pc4a5i32", abi_pa5i32);

    try testMangleInt("I1234ABCDp", 0x1234ABCD);
    try testMangleInt("I111122223333444455556666777n", -0x111122223333444455556666777);
    try testMangleInt("I0p", 0x0);
    try testMangleInt("I10000000000000000p", 0x10000000000000000);

    try testMangle("T", .{ .constant_bool = true });
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
    const abi_ci = .{ .constant_int = value.toConst() };
    try testDemangle(abi_ci, mangled);
}

test "AbiValue - demangle" {
    try testDemangle(.{ .int = .{ .signedness = .unsigned, .bits = 32 } }, "u32");
    try testDemangle(.{ .float = .{ .bits = 64 } }, "f64");
    const abi_i16 = .{ .int = .{ .signedness = .signed, .bits = 16 } };
    try testDemangle(abi_i16, "i16");
    const abi_a987i16 = .{ .array = .{ .len = 987, .child = &abi_i16 } };
    try testDemangle(abi_a987i16, "a987i16");
    const abi_pa987i16 = .{ .pointer = .{ .size = .slice, .is_const = false, .alignment = 123, .child = &abi_a987i16 } };
    try testDemangle(abi_pa987i16, "Sm123a987i16");

    try testDemangleInt(0x11223344, "I11223344p");
    try testDemangleInt(-0xAAAABBBBCCCCDDDDEEEEF, "IAAAABBBBCCCCDDDDEEEEFn");
    try testDemangleInt(0x0, "I00000000000000000000000000000n");

    try testDemangle(.{ .constant_bool = false }, "F");
}
