//! This file implements self-hosted functionality for creating clang offload bundles from
//! a set of inputs.
//! See also https://clang.llvm.org/docs/ClangOffloadBundler.html

const std = @import("std");
const build = std.build;
const Allocator = std.mem.Allocator;
const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;

const zhc = @import("../zhc.zig");

const clang_offload_bundle_magic = "__CLANG_OFFLOAD_BUNDLE__".*;

pub const OffloadKind = enum {
    host,
    hip,
    hipv4,
    openmp,
};

pub const Entry = struct {
    offload_kind: OffloadKind,
    target: Target,
    code_object: []const u8,

    /// https://clang.llvm.org/docs/ClangOffloadBundler.html#bundle-entry-id
    fn writeEntryId(self: Entry, writer: anytype) !void {
        // TODO: These enums do not always correspond to the llvm name, so this should
        // be improved at some point.
        try writer.print("{s}-{s}-{s}-{s}", .{
            @tagName(self.offload_kind),
            @tagName(self.target.cpu.arch),
            vendor(self.target),
            @tagName(self.target.os.tag),
        });

        if (self.target.abi != .none) {
            try writer.print("-{s}", .{@tagName(self.target.abi)});
        }

        try writer.print("-{s}", .{self.target.cpu.model.llvm_name orelse return error.UnsupportedTarget});

        for (self.target.cpu.arch.allFeaturesList()) |feature, index_usize| {
            const index = @intCast(Target.Cpu.Feature.Set.Index, index_usize);
            const is_enabled = self.target.cpu.features.isEnabled(index);
            if (!is_enabled) continue;

            if (feature.llvm_name) |llvm_name| {
                // Note: Currently only write the explicitly enabled features and not the disabled ones. This might need
                // to change, but annoyingly there are 2 different states for some features: enabled, disabled, and 'dont care'.
                // TODO: This adds a _lot_ of features, tools may not be able to deal with that.
                try writer.print(":{s}+", .{llvm_name});
            }
        }
    }

    fn entryIdSize(self: Entry) !usize {
        var counting_writer = std.io.countingWriter(std.io.null_writer);
        try self.writeEntryId(counting_writer.writer());
        return counting_writer.bytes_written;
    }
};

pub const Bundle = struct {
    alignment: usize = 4096,
    entries: []const Entry,
};

fn vendor(target: Target) []const u8 {
    return switch (target.os.tag) {
        .amdhsa, .amdpal => "amd",
        else => "unknown",
    };
}

pub fn bundle(bundle_writer: anytype, offload_bundle: Bundle) !void {
    const al = offload_bundle.alignment;
    // Compute the base offset of the code objects.
    // Start with sizeof magic + sizeof the number of entries
    var code_objects_offset = clang_offload_bundle_magic.len + @sizeOf(u64);
    for (offload_bundle.entries) |entry| {
        // Add code object offset (8 byte) + code object size (8 byte) + bundle id length (8 byte).
        code_objects_offset += @sizeOf(u64) * 3;
        // Add size of bundle entry id.
        code_objects_offset = try entry.entryIdSize();
    }

    // Align to the required code object alignment to get the final offset.
    code_objects_offset = std.mem.alignForward(code_objects_offset, al);

    var counting_writer = std.io.countingWriter(bundle_writer);
    const writer = counting_writer.writer();

    try writer.writeAll(&clang_offload_bundle_magic);
    try writer.writeIntLittle(u64, offload_bundle.entries.len);

    for (offload_bundle.entries) |entry| {
        // Write the bundle offsets and lengths.
        try writer.writeIntLittle(u64, code_objects_offset);
        try writer.writeIntLittle(u64, entry.code_object.len);
        try writer.writeIntLittle(u64, try entry.entryIdSize());
        try entry.writeEntryId(writer);
        // Advance the offset to that of the next code object.
        code_objects_offset = std.mem.alignForward(code_objects_offset + entry.code_object.len, al);
    }

    // Write the actual code objects. Be sure to mind alignment.
    for (offload_bundle.entries) |entry| {
        const padding = al - counting_writer.bytes_written % al;
        try writer.writeByteNTimes(0, padding);
        try writer.writeAll(entry.code_object);
    }
}

pub const OffloadBundleStep = struct {
    pub const StepEntry = struct {
        offload_kind: OffloadKind,
        object: *build.LibExeObjStep,
    };

    step: build.Step,
    b: *build.Builder,
    host_target: ?CrossTarget = null,
    entries: std.ArrayListUnmanaged(StepEntry) = .{},
    generated_file: build.GeneratedFile,

    pub fn create(b: *build.Builder) *OffloadBundleStep {
        const self = b.allocator.create(OffloadBundleStep) catch unreachable;
        self.* = .{
            .step = build.Step.init(.custom, "hip-fat-binary", b.allocator, make),
            .b = b,
            .generated_file = .{
                .step = &self.step,
            },
        };

        return self;
    }

    pub fn add(self: *OffloadBundleStep, entry: StepEntry) void {
        self.entries.append(self.b.allocator, entry) catch unreachable;
        self.step.dependOn(&entry.object.step);
    }

    pub fn setHostTarget(self: *OffloadBundleStep, host_target: CrossTarget) void {
        self.host_target = host_target;
    }

    pub fn getOutputSource(self: *build.LibExeObjStep) build.FileSource {
        return build.FileSource{ .generated = &self.generated_file };
    }

    fn make(step: *build.Step) !void {
        const self = @fieldParentPtr(OffloadBundleStep, "step", step);
        const cwd = std.fs.cwd();

        var entries = std.ArrayList(Entry).init(self.b.allocator);

        // Hip fat binaries need this empty host target for some reason.
        // Just add it here for ease.
        if (self.host_target) |host_target| {
            const host_target_info = try std.zig.system.NativeTargetInfo.detect(host_target);
            entries.append(.{
                .offload_kind = .host,
                .target = host_target_info.target,
                .code_object = &.{},
            }) catch unreachable;
        }

        for (self.entries.items) |entry| {
            const code_object_path = entry.object.getOutputSource().getPath(self.b);
            const code_object = zhc.build.elf.readBinary(self.b.allocator, cwd, code_object_path) catch unreachable;
            const code_object_target_info = try std.zig.system.NativeTargetInfo.detect(entry.object.target);

            entries.append(.{
                .offload_kind = entry.offload_kind,
                .target = code_object_target_info.target,
                .code_object = code_object,
            }) catch unreachable;
        }

        var out = std.ArrayList(u8).init(self.b.allocator);
        try bundle(out.writer(), .{
            .entries = entries.items,
        });

        // Hash contents to generate a file name.
        // Code taken from WriteFileStep.
        // TODO: Make this part some build utility?
        var hash = std.crypto.hash.blake2.Blake2b384.init(.{});
        // Random bytes to make this process unique. Refresh when the implementation
        // is modified in a non backwards compatible way.
        hash.update("Psb4YZnfgHJ38CNA");
        hash.update(out.items);
        var digest: [48]u8 = undefined;
        hash.final(&digest);
        var filename: [64]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&filename, &digest);

        const bundles_directory = self.b.pathFromRoot(
            try std.fs.path.join(
                self.b.allocator,
                &[_][]const u8{ self.b.cache_root, "offload_bundles" },
            ),
        );
        try cwd.makePath(bundles_directory);

        const bundle_path = try std.fs.path.join(
            self.b.allocator,
            &[_][]const u8{ bundles_directory, &filename },
        );

        try cwd.writeFile(bundle_path, out.items);

        self.generated_file.path = bundle_path;
    }
};
