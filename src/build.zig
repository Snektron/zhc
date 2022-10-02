//! Build-integration is exported here. When using ZHC build options,
//! it is advised to not use any functionality outside this path.

const std = @import("std");
const build = std.build;
const Builder = build.Builder;
const FileSource = build.FileSource;
const Step = build.Step;
const LibExeObjStep = build.LibExeObjStep;
const OptionsStep = build.OptionsStep;
const Pkg = build.Pkg;
const CrossTarget = std.zig.CrossTarget;

pub const elf = @import("build/elf.zig");
pub const offload_bundle = @import("build/offload_bundle.zig");
pub const hip_fatbin = @import("build/hip_fatbin.zig");
pub const amdgpu = @import("build/amdgpu.zig");

const zhc = @import("zhc.zig");
const KernelConfig = zhc.abi.KernelConfig;
const HipFatBinStep = hip_fatbin.HipFatBinStep;

const zhc_pkg_name = "zhc";
const zhc_options_pkg_name = "zhc_build_options";
const zhc_platform_options_pkg_name = "zhc_platform_build_options";

/// The path to the main file of this library.
const zhc_pkg_path = getZhcPkgPath();

fn getZhcPkgPath() []const u8 {
    const root = comptime std.fs.path.dirname(@src().file).?;
    return root ++ [_]u8{std.fs.path.sep} ++ "zhc.zig";
}

/// Get the configured ZHC package for host compilations
pub fn getHostPkg(b: *Builder) Pkg {
    const opts = getCommonZhcOptions(b, .host);
    const platform_opts = getPlatformZhcOptions(b, null);
    return configure(b, opts, platform_opts);
}

fn getCommonZhcOptions(b: *Builder, side: zhc.compilation.Side) *OptionsStep {
    const opts = b.addOptions();
    const out = opts.contents.writer();
    // Manually write the symbol so that we avoid a duplicate definition of `Side`.
    // `zhc.zig` re-exports this value to ascribe it with the right enum type.
    out.print("pub const side = .{s};\n", .{@tagName(side)}) catch unreachable;

    return opts;
}

fn getPlatformZhcOptions(b: *Builder, platform: ?zhc.platform.Kind) *OptionsStep {
    const opts = b.addOptions();
    const out = opts.contents.writer();

    if (platform) |p| {
        out.print("pub const platform = .{s};\n", .{@tagName(p)}) catch unreachable;
    }

    return opts;
}

/// Configure ZHC for compilation. `opts` is an `OptionsStep` that provides
/// `zhc_build_options`.
fn configure(
    b: *Builder,
    opts: *OptionsStep,
    platform_opts: *OptionsStep,
) Pkg {
    const deps = b.allocator.dupe(Pkg, &.{
        opts.getPackage(zhc_options_pkg_name),
        platform_opts.getPackage(zhc_platform_options_pkg_name),
    }) catch unreachable;

    return .{
        .name = zhc_pkg_name,
        .source = .{ .path = zhc_pkg_path },
        .dependencies = deps,
    };
}

/// This step is used to extract which kernels in a particular binary are present.
const KernelConfigExtractStep = struct {
    step: Step,
    b: *Builder,
    object_src: FileSource,
    /// The final array of kernel configs extracted from the source object's binary.
    /// This value is only valid after make() is called.
    configs: zhc.abi.Overload.Map,
    /// This step is used for `zhc_build_options` for a device, and has the
    /// kernel configs generated by this step.
    /// It is part of this step to save on some complexity, as it is pretty much
    /// always needed by uses of this step.
    device_options_step: *OptionsStep,

    fn create(
        b: *Builder,
        /// The (elf) object to extract kernel configuration symbols from.
        object_src: FileSource,
    ) *KernelConfigExtractStep {
        const self = b.allocator.create(KernelConfigExtractStep) catch unreachable;
        self.* = .{
            .step = Step.init(.custom, "extract-kernel-configs", b.allocator, make),
            .b = b,
            .object_src = object_src,
            .configs = undefined,
            .device_options_step = getCommonZhcOptions(b, .device),
        };
        self.object_src.addStepDependencies(&self.step);
        self.device_options_step.step.dependOn(&self.step);
        return self;
    }

    fn make(step: *Step) !void {
        // TODO: Something with the cache to see if this work is at all neccesary?
        const self = @fieldParentPtr(KernelConfigExtractStep, "step", step);
        const object_path = self.object_src.getPath(self.b);
        const binary = try elf.readBinary(self.b.allocator, std.fs.cwd(), object_path);
        self.configs = try elf.parseKernelConfigs(self.b.allocator, binary);

        if (self.b.verbose) {
            std.log.info("Found {} kernel config(s):", .{self.configs.count()});

            var it = self.configs.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.*) |overload| {
                    std.log.info("  {s}({})", .{ entry.key_ptr.*, overload });
                }
            }
        }

        // Add the generated configs to the options step.
        const out = self.device_options_step.contents.writer();
        try out.writeAll("pub const launch_configurations = struct {\n");

        var it = self.configs.iterator();
        while (it.next()) |entry| {
            try out.print("    pub const {} = &.{{\n", .{std.zig.fmtId(entry.key_ptr.*)});
            for (entry.value_ptr.*) |overload| {
                try out.writeAll(" " ** 8);
                try overload.toStaticInitializer(out);
                try out.writeAll(",\n");
            }
            try out.writeAll("    };\n");
        }

        try out.writeAll("};\n");
    }
};

pub fn extractKernelConfigs(builder: *Builder, object_step: *LibExeObjStep) *KernelConfigExtractStep {
    return extractKernelConfigsSource(builder, object_step.getOutputSource());
}

pub fn extractKernelConfigsSource(builder: *Builder, object_src: FileSource) *KernelConfigExtractStep {
    return KernelConfigExtractStep.create(builder, object_src);
}

/// This step represents a compilation of a "kernel-object": An object file that contains the
/// device machine code for a set of kernels. Zig code in a device object is compiled in
/// device-mode for a particular architecture.
pub const DeviceObjectStep = struct {
    step: Step,
    b: *Builder,
    platform: zhc.platform.Kind,
    object: *LibExeObjStep,
    configs_step: *KernelConfigExtractStep,

    fn create(
        b: *Builder,
        /// The main source file for this device lib.
        root_src: FileSource,
        /// The kind of platform this device library is being compiled for.
        platform: zhc.platform.Kind,
        /// Step which resolves the kernel configurations that this device library
        /// should compile.
        configs_step: *KernelConfigExtractStep,
    ) *DeviceObjectStep {
        const self = b.allocator.create(DeviceObjectStep) catch unreachable;
        self.* = .{
            // TODO: Better name?
            .step = Step.init(.custom, "kernel-object", b.allocator, make),
            .b = b,
            .platform = platform,
            .object = b.addSharedLibrarySource("device-code", root_src, .unversioned),
            .configs_step = configs_step,
        };

        const platform_opts = getPlatformZhcOptions(b, platform);
        const zhc_pkg = configure(b, configs_step.device_options_step, platform_opts);

        self.object.addPackage(zhc_pkg);
        self.object.linker_allow_shlib_undefined = false;
        self.object.bundle_compiler_rt = true;
        self.object.force_pic = true;

        // TODO: These dependencies might not be correct.
        self.step.dependOn(&self.object.step);
        self.step.dependOn(&self.configs_step.step);

        return self;
    }

    pub fn setBuildMode(self: *DeviceObjectStep, mode: std.builtin.Mode) void {
        self.object.setBuildMode(mode);
    }

    pub fn setTarget(self: *DeviceObjectStep, target: CrossTarget) void {
        self.object.setTarget(target);
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(DeviceObjectStep, "step", step);
        _ = self;

        // Do we actually need this step? Can we not just do with a function that
        // returns a regular LibExeObjStep?

        // That might still need a target, but we can hack that into by creating a separate step that
        // detects gpus and adds it there.
    }
};

pub fn addDeviceObject(
    builder: *Builder,
    root_src: []const u8,
    platform: zhc.platform.Kind,
    configs: *KernelConfigExtractStep
) *DeviceObjectStep {
    return addDeviceObjectSource(builder, .{ .path = root_src }, platform, configs);
}

pub fn addDeviceObjectSource(
    builder: *Builder,
    root_src: FileSource,
    platform: zhc.platform.Kind,
    configs: *KernelConfigExtractStep
) *DeviceObjectStep {
    return DeviceObjectStep.create(builder, root_src, platform, configs);
}

/// The OffloadLibraryStep produces a library containing all the device code, that can be linked with
/// a host executable that contains ZHC kernel calls.
pub const OffloadLibraryStep = struct {
    step: Step,
    b: *Builder,
    host_target: CrossTarget = .{},
    hip_fatbin_step: ?*HipFatBinStep = null,

    fn create(b: *Builder) *OffloadLibraryStep {
        const self = b.allocator.create(OffloadLibraryStep) catch unreachable;
        self.* = .{
            .step = Step.init(.custom, "offload-library", b.allocator, make),
            .b = b,
        };
        return self;
    }

    /// Set the host target that this library should be compiled for.
    pub fn setTarget(self: *OffloadLibraryStep, target: CrossTarget) void {
        self.host_target = target;
        if (self.hip_fatbin_step) |hip_fatbin_step| {
            hip_fatbin_step.setHostTarget(target);
        }
    }

    /// Add a device object to this offload library.
    pub fn addKernels(self: *OffloadLibraryStep, device_object: *DeviceObjectStep) void {
        // TODO: If we want to autodetect then this value might not be available at this time,
        // and so it should be deferred onto the make step?
        // Or we can just force the user to give the platform up front, but provide a function to detect it.
        switch (device_object.platform) {
            .amdgpu => self.addAmdgpuKernels(device_object),
        }
    }

    fn addAmdgpuKernels(self: *OffloadLibraryStep, device_object: *DeviceObjectStep) void {
        if (self.hip_fatbin_step == null) {
            self.hip_fatbin_step = HipFatBinStep.create(self.b);
            self.hip_fatbin_step.?.setHostTarget(self.host_target);
            self.step.dependOn(&self.hip_fatbin_step.?.step);
        }

        self.hip_fatbin_step.?.add(device_object);
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(OffloadLibraryStep, "step", step);
        _ = self;
    }
};

pub fn addOffloadLibrary(builder: *Builder) *OffloadLibraryStep {
    return addOffloadLibrarySource(builder);
}

pub fn addOffloadLibrarySource(builder: *Builder) *OffloadLibraryStep {
    return OffloadLibraryStep.create(builder);
}

