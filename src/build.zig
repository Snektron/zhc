//! This file defines build-integration for ZHC.
const std = @import("std");
const zhc = @import("zhc.zig");

const CrossTarget = std.zig.CrossTarget;

const build = std.build;
const Builder = build.Builder;
const FileSource = build.FileSource;
const Step = build.Step;
const LibExeObjStep = build.LibExeObjStep;
const OptionsStep = build.OptionsStep;
const Pkg = build.Pkg;

const zhc_pkg_name = "zhc";
const zhc_options_pkg_name = "zhc_build_options";

/// Configure ZHC for compilation to a particular side.
/// `zhc_pkg_path` is the path to the zhc package itself (src/zhc.zig).
/// `side` is the side that dependents compile for - host or device code.
pub fn configure(
    b: *Builder,
    zhc_pkg_path: []const u8,
    side: zhc.compilation.Side,
) Pkg {
    const opts = b.addOptions();
    // Note: This will create a duplicate `Side` enum. This is dealt with by re-exporting
    // options with the proper type in zhc.zig. Options are to be accessed through
    // `@import("zhc").build_options`.
    opts.addOption(zhc.compilation.Side, "side", side);

    const deps = b.allocator.dupe(Pkg, &.{
        opts.getPackage(zhc_options_pkg_name),
    }) catch unreachable;

    return .{
        .name = zhc_pkg_name,
        .source = .{.path = zhc_pkg_path},
        .dependencies = deps,
    };
}

/// This step is used to compile a "device-library" step for a particular architecture.
/// The Zig code associated to this step is compiled in "device-mode", and the produced
/// elf file is to be linked with a host executable or library.
pub const DeviceLibStep = struct {
    step: Step,
    device_lib: *LibExeObjStep,

    pub fn create(
        b: *Builder,
        /// The main source file for this device lib.
        root_src: FileSource,
        zhc_pkg_path: []const u8,
        /// The device architecture to compile for.
        device_target: CrossTarget,
        // TODO: Kernel configurations.
    ) *DeviceLibStep {
        const self = b.allocator.create(DeviceLibStep) catch unreachable;
        self.* = .{
            // TODO: Better name?
            .step = Step.init(.custom, "device-lib", b.allocator, make),
            .device_lib = b.addStaticLibrarySource("device-lib-library", root_src),
        };
        self.step.dependOn(&self.device_lib.step);
        self.device_lib.setTarget(device_target);
        self.device_lib.addPackage(configure(b, zhc_pkg_path, .device));
        return self;
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(DeviceLibStep, "step", step);
        std.debug.print("finished compiling device-lib-library, kernels would be extracted here\n", .{});
        _ = self;
    }
};

pub fn addDeviceLib(self: *Builder, root_src: []const u8, zhc_pkg_path: []const u8, device_target: CrossTarget) *DeviceLibStep {
    return addDeviceLibSource(self, .{.path = root_src}, zhc_pkg_path, device_target);
}

pub fn addDeviceLibSource(builder: *Builder, root_src: FileSource, zhc_pkg_path: []const u8, device_target: CrossTarget) *DeviceLibStep {
    return DeviceLibStep.create(builder, root_src, zhc_pkg_path, device_target);
}
