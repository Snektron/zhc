//! This file deals with the amdgpu specifics of the build process.

const std = @import("std");
const log = std.log;
const build = std.build;
const Allocator = std.mem.Allocator;

pub const code_object = @import("amdgpu/code_object.zig");
pub const hip_fatbin = @import("amdgpu/hip_fatbin.zig");

const zhc = @import("../zhc.zig");
const msgpack = zhc.util.msgpack;
const elf_align = zhc.build.elf.elf_align;
const ElfParser = zhc.build.elf.ElfParser;
const KernelConfig = zhc.abi.KernelConfig;

/// This struct tracks metadata information related to the device object, which can
/// later be used to embed information about the executables into the offload library.
pub const ObjectMetadata = struct {
    /// A kernel (overload) present in this binary.
    const Kernel = struct {
        elf_sym: []const u8,
    };

    /// The kernels present in this binary. This slice has the same order as
    /// the `configs` passed to the `objectMetadata` function it was derived from.
    kernels: []Kernel,

    /// HSA targets kind of differ from LLVM/Zigs. Luckily the binary encodes it in its metadata,
    /// so we can extract it and then pass this to the offload bundler.
    hsa_target: []const u8,
};

/// Extract kernel metadata from a code object. Returns a slice of kernel metadata,
/// where each index corresponds to the overload with the same index in `overloads`.
pub fn objectMetadata(
    a: Allocator,
    object: []align(elf_align) const u8,
    configs: KernelConfig.MangleMap,
) !ObjectMetadata {
    var elf_parser = try ElfParser.init(object);
    // TODO: This should be checked somewhere in DeviceObjectStep before this function is called,
    // and with more general code than this.
    std.debug.assert(elf_parser.header.machine == .AMDGPU);

    const elf_metadata = blk: {
        var it = try elf_parser.notesIterator();
        while (it.next()) |note| {
            if (!std.mem.eql(u8, note.name, "AMDGPU")) continue;
            if (note.note_type != code_object.NT_AMDGPU_METADATA) return error.InvalidElf;

            var metadata_parser = msgpack.Parser.init(a, note.desc);
            break :blk try metadata_parser.parse(code_object.CodeObjectV345Metadata);
        }

        return error.InvalidElf;
    };

    const kernels = try a.alloc(ObjectMetadata.Kernel, configs.count());
    var seen_kernels = try std.DynamicBitSetUnmanaged.initEmpty(a, configs.count());

    for (elf_metadata.@"amdhsa.kernels") |kernel| {
        const name = kernel.@".name";
        const mangled_name = zhc.util.removePrefix(name, zhc.abi.mangling.kernel_declaration_sym_prefix).?;
        const index = configs.getIndex(mangled_name) orelse return error.UnknownConfig;
        seen_kernels.set(index);

        kernels[index] = .{
            .elf_sym = kernel.@".symbol",
        };
    }

    // TODO: This should probably go somewhere more general...
    var it = seen_kernels.iterator(.{.kind = .unset});
    var any_unseen = false;
    while (it.next()) |bit| {
        const config = configs.values()[bit];
        // TODO: Report overload arguments.
        log.err("missing kernel declaration for '{}'", .{config});
        any_unseen = true;
    }

    // TODO: Also improve this part.
    //   This does not return an error because that generates a long trace, while
    //   this is a more user-facing error (it occurs when the user forgot to declare
    //   a kernel) rather than an internal error, and so it should be somewhat pretty.
    if (any_unseen) {
        std.os.exit(1);
    }

    return ObjectMetadata{
        .kernels = kernels,
        // Note: amdhsa.target is only valid since code object V4.
        // TODO: We should probably check that somewhere, though in practise Zig will always generate V4+.
        .hsa_target = elf_metadata.@"amdhsa.target".?,
    };
}
