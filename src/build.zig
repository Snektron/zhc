//! Build-integration is exported here. When using ZHC build options,
//! it is advised to not use any functionality outside this path.

const std = @import("std");
const zhc = @import("zhc.zig");

pub const elf = @import("build/elf.zig");

const CrossTarget = std.zig.CrossTarget;
const native_endian = @import("builtin").target.cpu.arch.endian();

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
    const out = opts.contents.writer();
    // Manually write the symbol so that we avoid a duplicate definition of `Side`.
    // `zhc.zig` re-exports this value to ascribe it with the right enum type.
    out.print("pub const side = .{s};\n", .{@tagName(side)}) catch unreachable;

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

    pub fn setBuildMode(self: *DeviceLibStep, mode: std.builtin.Mode) void {
        self.device_lib.setBuildMode(mode);
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

/// This step is used to extract which kernels in a particular binary are
/// present.
pub const KernelConfigExtractStep = struct {
    step: Step,
    b: *Builder,
    object_src: FileSource,

    pub fn create(
        b: *Builder,
        /// The (elf) object to extract kernel configuration symbols from.
        object_src: FileSource,
    ) *KernelConfigExtractStep {
        const self = b.allocator.create(KernelConfigExtractStep) catch unreachable;
        self.* = .{
            .step = Step.init(.custom, "kernel-config-extract", b.allocator, make),
            .b = b,
            .object_src = object_src,
        };
        self.object_src.addStepDependencies(&self.step);
        return self;
    }

    fn make(step: *Step) !void {
        // TODO: Something with the cache to see if this work is all neccesary?
        const self = @fieldParentPtr(KernelConfigExtractStep, "step", step);
        const object_path = self.object_src.getPath(self.b);
        const elf_bytes = try std.fs.cwd().readFileAllocOptions(
            self.b.allocator,
            object_path,
            std.math.maxInt(usize),
            1 * 1024 * 1024,
            @alignOf(std.elf.Elf64_Ehdr),
            null,
        );

        const configs = try elf.parseKernelConfigs(self.b.allocator, elf_bytes);
        std.log.info("Found {} configs:", .{configs.len});
        for (configs) |cfg| {
            std.log.info("{}", .{cfg});
        }
    }
};
