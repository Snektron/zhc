//! This file contains functions that deal with elf files,
//! such as extracting kernel configurations.

const std = @import("std");
const zhc = @import("../zhc.zig");

const elf = std.elf;
const Allocator = std.mem.Allocator;
const native_endian = @import("builtin").target.cpu.arch.endian();

const KernelConfig = zhc.abi.KernelConfig;
const Overload = zhc.abi.Overload;

pub const ParseKernelConfigsError = error{
    InvalidElf,
    InvalidMangledName,
    OutOfMemory,
};

fn KernelConfigParser(comptime is_64: bool, comptime endian: std.builtin.Endian) type {
    return struct {
        const Sym = if (is_64) elf.Elf64_Sym else elf.Elf32_Sym;
        const Shdr = if (is_64) elf.Elf64_Shdr else elf.Elf32_Shdr;

        fn parse(header: elf.Header, binary: []const u8, arena: Allocator) !Overload.Map {
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

            var overloads = std.StringArrayHashMap(std.ArrayListUnmanaged(Overload)).init(arena);

            for (syms) |sym| {
                const name = std.mem.sliceTo(strtab[endianFix(sym.st_name)..], 0);
                if (!std.mem.startsWith(u8, name, zhc.abi.mangling.kernel_array_sym_prefix)) {
                    continue;
                }

                const config = try KernelConfig.demangle(arena, name[zhc.abi.mangling.kernel_array_sym_prefix.len..]);
                const entry = try overloads.getOrPut(config.kernel.name);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{};
                }

                // Note: Assume that the binary only contains _unique_ symbols.
                // While elf technically allows it, we only emit the symbol for each once.
                // TODO: Is that correct? What about libraries?
                try entry.value_ptr.append(arena, config.overload);
            }

            var actual_overloads = Overload.Map{};
            try actual_overloads.ensureTotalCapacity(arena, overloads.count());

            var it = overloads.iterator();
            while (it.next()) |entry| {
                actual_overloads.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.items);
            }

            return actual_overloads;
        }

        fn endianFix(x: anytype) @TypeOf(x) {
            if (endian != native_endian) {
                return @byteSwap(x);
            } else {
                return x;
            }
        }
    };
}

/// Retrieve a list of kernel configurations that the binary needs. These are
/// communicated by symbols starting with `__zhc_ka_ ` and followed by a mangled
/// `zhc.abi.KernelConfig`. This function returns the full list of symbols.
/// Note: `a` must be an arena allocator.
pub fn parseKernelConfigs(
    arena: Allocator,
    binary: []align(@alignOf(elf.Elf64_Ehdr)) const u8,
) ParseKernelConfigsError!Overload.Map {
    const header = elf.Header.parse(binary[0..@sizeOf(elf.Elf64_Ehdr)]) catch return error.InvalidElf;
    return switch (header.is_64) {
        true => switch (header.endian) {
            .Big => try KernelConfigParser(true, .Big).parse(header, binary, arena),
            .Little => try KernelConfigParser(true, .Little).parse(header, binary, arena),
        },
        false => switch (header.endian) {
            .Big => try KernelConfigParser(false, .Big).parse(header, binary, arena),
            .Little => try KernelConfigParser(false, .Little).parse(header, binary, arena),
        },
    };
}
