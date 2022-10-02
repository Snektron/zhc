//! This file deals with the amdgpu specifics of the build process.

const std = @import("std");
const build = std.build;
const Allocator = std.mem.Allocator;

const zhc = @import("../zhc.zig");
const offload_bundle = zhc.build.offload_bundle;
const DeviceObjectStep = zhc.build.DeviceObjectStep;
const elf_align = zhc.build.elf.elf_align;
const ElfParser = zhc.build.elf.ElfParser;
const msgpack = zhc.util.msgpack;

// TODO: hipFatBinSegment/__hip_fatbin_wrapper
// TODO: Less hardcoding
const fat_bin_template =
    \\export const __hip_fatbin align(4096) linksection(".hip_fatbin") = @embedFile("{s}").*;
    \\
;

fn createOffloadBundle(b: *build.Builder, host_target: std.Target, device_objects: []const *DeviceObjectStep) ![]const u8 {
    var entries = std.ArrayList(offload_bundle.Entry).init(b.allocator);

    // Hip fat binaries need this empty host target for some reason.
    entries.append(.{
        .offload_kind = .host,
        .target = host_target,
        .code_object = &.{},
    }) catch unreachable;

    for (device_objects) |device_object| {
        std.debug.assert(device_object.platform == .amdgpu);

        const code_object_target_info = try std.zig.system.NativeTargetInfo.detect(device_object.object.target);

        entries.append(.{
            .offload_kind = .hipv4,
            .target = code_object_target_info.target,
            .code_object = device_object.object_data,
        }) catch unreachable;
    }

    var out = std.ArrayList(u8).init(b.allocator);
    try offload_bundle.bundle(out.writer(), .{
        .entries = entries.items,
    });

    return out.items;
}

fn hashToDirName(b: *build.Builder, contents: []const u8) ![]const u8 {
    var hash = std.crypto.hash.blake2.Blake2b384.init(.{});
    hash.update("Psb4YZnfgHJ38CNA");
    hash.update(contents);
    var digest: [48]u8 = undefined;
    hash.final(&digest);
    var base_dirname: [64]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&base_dirname, &digest);

    const dir = b.pathFromRoot(
        try std.fs.path.join(
            b.allocator,
            &[_][]const u8{ b.cache_root, "hipfb", &base_dirname },
        ),
    );

    return dir;
}

fn join2(a: Allocator, dirname: []const u8, filename: []const u8) ![]const u8 {
    return try std.fs.path.join(a, &.{ dirname, filename });
}

pub fn buildHipFatBinary(
    b: *build.Builder,
    host_target: std.Target,
    device_objects: []const *DeviceObjectStep,
) ![]const u8 {
    // First, build an offload bundle using all the device objects.
    const bundle = try createOffloadBundle(b, host_target, device_objects);

    // Hash the bundle to get a "work" dir.
    const dirname = try hashToDirName(b, bundle);
    const cwd = std.fs.cwd();
    try cwd.makePath(dirname);

    const bundle_path = try join2(b.allocator, dirname, "offload_bundle.hipfb");
    const hipfb_zig_path = try join2(b.allocator, dirname, "hipfatbin.zig");
    const hipfb_bin_path = try join2(b.allocator, dirname, "hipfatbin.o");

    // Place the bundle in the "work" dir.
    try cwd.writeFile(bundle_path, bundle);

    // Generate some Zig code that we can use to compile the bundle.
    const code = try std.fmt.allocPrint(b.allocator, fat_bin_template, .{bundle_path});
    try cwd.writeFile(hipfb_zig_path, code);

    // Finally, build an object file from the generated zig file.
    _ = try b.exec(&.{
        b.zig_exe,
        "build-obj",
        hipfb_zig_path,
        "--main-pkg-path",
        dirname,
        "-target",
        try host_target.zigTriple(b.allocator),
        try std.fmt.allocPrint(b.allocator, "-femit-bin={s}", .{hipfb_bin_path}),
    });

    return hipfb_bin_path;
}
