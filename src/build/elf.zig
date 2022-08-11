//! This file contains functions that deal with elf files,
//! such as extracting kernel configurations.

const std = @import("std");
const zhc = @import("../zhc.zig");

const elf = std.elf;
const Allocator = std.mem.Allocator;
const native_endian = @import("builtin").target.cpu.arch.endian();

const KernelConfig = zhc.abi.KernelConfig;

pub const ParseKernelConfigsError = error{
    InvalidMangledName,
    InvalidElf,
    OutOfMemory,
};

fn KernelConfigParser(comptime is_64: bool, comptime endian: std.builtin.Endian) type {
    return struct {
        const Sym = if (is_64) elf.Elf64_Sym else elf.Elf32_Sym;
        const Shdr = if (is_64) elf.Elf64_Shdr else elf.Elf32_Shdr;

        fn parse(header: elf.Header, binary: []const u8, a: Allocator) ![]KernelConfig {
            const shdrs = std.mem.bytesAsSlice(Shdr, binary[header.shoff..])[0..header.shnum];
            const shstrtab_offset = endianFix(shdrs[header.shstrndx].sh_offset);
            const shstrtab = binary[shstrtab_offset..];

            // Find offsets of the .symtab table.
            const symtab_index = for (shdrs) |shdr, i| {
                const sh_name = std.mem.sliceTo(shstrtab[endianFix(shdr.sh_name)..], 0);
                if (std.mem.eql(u8, sh_name, ".symtab")) {
                    break @intCast(u16, i);
                }
            } else {
                return error.InvalidElf;
            };

            const strtab_offset = endianFix(shdrs[endianFix(shdrs[symtab_index].sh_link)].sh_offset);
            const strtab = binary[strtab_offset..];

            const syms_off = endianFix(shdrs[symtab_index].sh_offset);
            const syms_size = endianFix(shdrs[symtab_index].sh_size);
            const syms = std.mem.bytesAsSlice(Sym, binary[syms_off..][0..syms_size]);

            // Count symbols so that we only need to allocate once, to make this function
            // more fiendly to arena allocators.
            var num_configs: usize = 0;
            for (syms) |sym| {
                const name = std.mem.sliceTo(strtab[endianFix(sym.st_name)..], 0);
                if (std.mem.startsWith(u8, name, zhc.abi.kernel_array_sym_prefix)) {
                    num_configs += 1;
                }
            }

            const configs = try a.alloc(KernelConfig, num_configs);
            errdefer a.free(configs);

            var i: usize = 0;
            for (syms) |sym| {
                const name = std.mem.sliceTo(strtab[endianFix(sym.st_name)..], 0);
                if (!std.mem.startsWith(u8, name, zhc.abi.kernel_array_sym_prefix)) {
                    continue;
                }
                configs[i] = try KernelConfig.demangle(a, name[zhc.abi.kernel_array_sym_prefix.len..]);
                i += 1;
            }
            return configs;
        }

        fn endianFix(x: anytype) @TypeOf(x) {
            if (endian != native_endian) {
                return @byteSwap(@TypeOf(x), x);
            } else {
                return x;
            }
        }
    };
}

/// Retrieve a list of kernel configurations that the binary needs. These are
/// communicated by symbols starting with `__zhc_ka_ ` and followed by a mangled
/// `zhc.abi.KernelConfig`.
pub fn parseKernelConfigs(
    a: Allocator,
    binary: []align(@alignOf(elf.Elf64_Ehdr)) const u8,
) ParseKernelConfigsError![]KernelConfig {
    const header = elf.Header.parse(binary[0..@sizeOf(elf.Elf64_Ehdr)]) catch return error.InvalidElf;
    return switch (header.is_64) {
        true => switch (header.endian) {
            .Big => try KernelConfigParser(true, .Big).parse(header, binary, a),
            .Little => try KernelConfigParser(true, .Little).parse(header, binary, a),
        },
        false => switch (header.endian) {
            .Big => try KernelConfigParser(false, .Big).parse(header, binary, a),
            .Little => try KernelConfigParser(false, .Little).parse(header, binary, a),
        },
    };
}
