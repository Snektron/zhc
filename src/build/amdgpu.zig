//! This file deals with the amdgpu specifics of the build process.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zhc = @import("../zhc.zig");
const msgpack = zhc.util.msgpack;
const elf_align = zhc.build.elf.elf_align;
const ElfParser = zhc.build.elf.ElfParser;

const NT_AMDGPU_METADATA = 32;

/// This structure is encoded in msgpack format in AMDGPU code objects. It is valid for
/// code objects V3, V4 and V5.
const CodeObjectV345Metadata = struct {
    @"amdhsa.version": [2]u64, // 1.0 for V3, 1.1 for V4, 1.2 for V5.
    @"amdhsa.printf": ?[]const []const u8 = null,
    @"amdhsa.target": ?[]const u8 = null, // Only present in V4+
    @"amdhsa.kernels": []const Kernel = &.{},

    const Kernel = struct {
        @".name": []const u8,
        @".symbol": []const u8,
        @".language": ?[]const u8 = null,
        @".language_version": ?[2]u64 = null,
        @".args": []const Arg = &.{},
        @".reqd_workgroup_size": ?[3]u64 = null,
        @".workgroup_size_limit": ?[3]u64 = null,
        @".vec_type_hint": ?[]const u8 = null,
        @".device_enqueue_symbol": ?[]const u8 = null,
        @".kernarg_segment_size": u64,
        @".group_segment_fixed_size": u64,
        @".private_segment_fixed_size": u64,
        @".kernarg_segment_align": u64,
        @".uses_dynamic_stack": bool = false,
        @".wavefront_size": u64,
        @".sgpr_count": u64,
        @".vgpr_count": u64,
        @".max_flat_workgroup_size": u64,
        @".sgpr_spill_count": u64 = 0,
        @".vgpr_spill_count": u64 = 0,
        @".kind": Kind = .normal,

        const Kind = enum {
            normal,
            init,
            fini,
        };
    };

    const Arg = struct {
        @".name": ?[]const u8 = null,
        @".type_name": ?[]const u8 = null,
        @".size": u64,
        @".offset": u64,
        @".value_kind": ValueKind,
        @".value_type": ?[]const u8 = null,
        @".pointee_align": ?u64 = null,
        @".address_space": ?AddressSpace = null,
        @".access": ?Access = null,
        @".actual_access": ?Access = null,
        @".is_const": bool = false,
        @".is_restrict": bool = false,
        @".is_volatile": bool = false,
        @".is_pipe": bool = false,

        const ValueKind = enum {
            by_value,
            global_buffer,
            dynamic_shared_buffer,
            sampler,
            image,
            pipe,
            queue,
            hidden_global_offset_x,
            hidden_global_offset_y,
            hidden_none,
            hidden_printf_buffer,
            hidden_hostcall_buffer,
            hidden_default_queue,
            hidden_completion_action,
            hidden_multigrid_sync_arg,
            hidden_block_count_x,
            hidden_block_count_y,
            hidden_block_count_z,
            hidden_group_size_x,
            hidden_group_size_y,
            hidden_group_size_z,
            hidden_remainder_x,
            hidden_remainder_y,
            hidden_remainder_z,
            hidden_grid_dims,
            hidden_heap_v1,
            hidden_private_base,
            hidden_shared_base,
            hidden_queue_ptr,
        };

        const AddressSpace = enum {
            private,
            global,
            constant,
            local,
            generic,
            region,
        };

        const Access = enum {
            read_only,
            write_only,
            read_write,
        };
    };
};

pub fn extractKernels(arena: Allocator, binary: []align(elf_align) const u8) !void {
    var elf_parser = try ElfParser.init(binary);
    if (elf_parser.header.machine != .AMDGPU) {
        // Expected amdgpu kernel binary to have, well, the AMDGPU arch.
        return error.InvalidElf;
    }

    const metadata_pack = blk: {
        // AMDGPU metadata is described in the .note section, with name "AMDGPU".
        var it = try elf_parser.notesIterator();
        while (it.next()) |note| {
            if (!std.mem.eql(u8, note.name, "AMDGPU")) continue;
            if (note.note_type != NT_AMDGPU_METADATA) return error.InvalidElf;
            break :blk note.desc;
        }

        return error.InvalidElf; // elf AMDGPU note missing
    };

    var metadata_parser = msgpack.Parser.init(arena, metadata_pack);
    const metadata = try metadata_parser.parse(CodeObjectV345Metadata);
    _ = metadata;
}
