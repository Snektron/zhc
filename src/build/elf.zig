//! This file contains functions that deal with elf files,
//! such as extracting kernel configurations.

const std = @import("std");
const zhc = @import("../zhc.zig");

const elf = std.elf;
const Allocator = std.mem.Allocator;
const native_endian = @import("builtin").target.cpu.arch.endian();
const Endian = std.builtin.Endian;

const KernelConfig = zhc.abi.KernelConfig;

pub const elf_align = @alignOf(elf.Elf64_Ehdr);

pub const ElfParser = struct {
    const Self = @This();
    const Sym = elf.Elf64_Sym;
    const Shdr = elf.Elf64_Shdr;
    const Nhdr = elf.Elf64_Nhdr;

    header: elf.Header,
    binary: []align(elf_align) const u8,
    section_headers: []const Shdr,
    section_header_strtab: []const u8,
    symtab: []const Sym,
    strtab: []const u8,

    pub fn init(binary: []align(elf_align) const u8) !Self {
        const header = elf.Header.parse(binary[0..@sizeOf(elf.Elf64_Ehdr)]) catch return error.InvalidElf;

        // There are virtually no notable devices that are not 64-bit little endian, so just return an error
        // if we ever come across one of these...
        // Same for big endian architectures in general.
        // TODO: Make sure that ^ is enforced.
        if (!header.is_64 or header.endian != .Little) {
            std.log.err("non 64-bit, non-little endian device architecture not supported by ZHC", .{});
            return error.InvalidElf;
        }

        const shdrs = std.mem.bytesAsSlice(Shdr, binary[header.shoff..])[0..header.shnum];
        const shstrtab_offset = shdrs[header.shstrndx].sh_offset;
        const shstrtab = binary[shstrtab_offset..];

        var self = Self{
            .header = header,
            .binary = binary,
            .section_headers = @alignCast(elf_align, shdrs),
            .section_header_strtab = shstrtab,
            .symtab = undefined,
            .strtab = undefined,
        };

        const symtab_shdr = self.findSectionHeader(".symtab") orelse return error.InvalidElf;
        self.symtab = @alignCast(elf_align, std.mem.bytesAsSlice(Sym, binary[symtab_shdr.sh_offset..][0..symtab_shdr.sh_size]));

        const strtab_offset = shdrs[symtab_shdr.sh_link].sh_offset;
        self.strtab = binary[strtab_offset..];

        return self;
    }

    pub fn findSectionHeader(self: Self, name: []const u8) ?Shdr {
        for (self.section_headers) |shdr| {
            const sh_name = std.mem.sliceTo(self.section_header_strtab[shdr.sh_name..], 0);
            if (std.mem.eql(u8, sh_name, name)) {
                return shdr;
            }
        }

        return null;
    }

    pub fn notesIterator(self: Self) !NoteIterator {
        const note_shdr = self.findSectionHeader(".note") orelse return error.InvalidElf;
        if (note_shdr.sh_type != std.elf.SHT_NOTE) {
            return error.InvalidElf;
        }

        const notes = self.binary[note_shdr.sh_offset..][0..note_shdr.sh_size];
        return NoteIterator{
            .remaining_notes = @alignCast(@alignOf(Nhdr), notes),
        };
    }

    pub const Note = struct {
        name: [:0]const u8,
        desc: []const u8,
        note_type: u64,
    };

    pub const NoteIterator = struct {
        remaining_notes: []align(@alignOf(Nhdr)) const u8,

        pub fn next(self: *NoteIterator) ?Note {
            if (self.remaining_notes.len == 0) {
                return null;
            }

            const nhdr = std.mem.bytesAsValue(Nhdr, self.remaining_notes[0..@sizeOf(Nhdr)]);
            const name = self.remaining_notes[@sizeOf(Nhdr)..][0 .. nhdr.n_namesz - 1 :0];
            const desc_offset = std.mem.alignForward(@sizeOf(Nhdr) + nhdr.n_namesz, @alignOf(Nhdr));
            const desc = self.remaining_notes[desc_offset..][0..nhdr.n_descsz];
            const note_size = std.mem.alignForward(desc_offset + nhdr.n_descsz, @alignOf(Nhdr));

            self.remaining_notes.len -= note_size;
            self.remaining_notes.ptr = @intToPtr([*]align(@alignOf(Nhdr)) const u8, @ptrToInt(self.remaining_notes.ptr) + note_size);

            return Note{
                .name = name,
                .desc = desc,
                .note_type = nhdr.n_type,
            };
        }
    };
};

pub fn readBinary(a: Allocator, cwd: std.fs.Dir, path: []const u8) ![]align(elf_align) u8 {
    return try cwd.readFileAllocOptions(
        a,
        path,
        std.math.maxInt(usize),
        1 * 1024 * 1024,
        elf_align,
        null,
    );
}

pub const ParseKernelConfigsError = error{
    InvalidElf,
    InvalidMangledName,
    OutOfMemory,
};

/// Retrieve a list of kernel configurations that the binary needs. These are
/// communicated by symbols starting with `__zhc_ka_ ` and followed by a mangled
/// `zhc.abi.KernelConfig`. This function returns the full list of symbols.
/// The returned hash map is ordened by the value's kernel name so that kernels
/// of the same name can be accessed sequentially.
/// Note: `arena` must be an arena allocator.
pub fn parseKernelConfigs(
    arena: Allocator,
    binary: []align(elf_align) const u8,
) ParseKernelConfigsError!KernelConfig.MangleMap {
    var parser = try ElfParser.init(binary);
    var configs = KernelConfig.MangleMap{};

    for (parser.symtab) |sym| {
        const name = std.mem.sliceTo(parser.strtab[sym.st_name..], 0);
        const mangled_name = zhc.util.removePrefix(name, zhc.abi.mangling.kernel_array_sym_prefix) orelse continue;
        const config = try KernelConfig.demangle(arena, mangled_name);
        try configs.put(arena, mangled_name, config);
    }

    const Cmp = struct {
         kernel_configs: []KernelConfig,

         pub fn lessThan(cmp: @This(), a_index: usize, b_index: usize) bool {
             const a = cmp.kernel_configs[a_index];
             const b = cmp.kernel_configs[b_index];
             return std.mem.order(u8, a.kernel.name, b.kernel.name).compare(.lt);
         }
    };

    configs.sort(Cmp{.kernel_configs = configs.values()});

    return configs;
}
