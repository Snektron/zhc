const std = @import("std");
const zhc = @import("src/zhc.zig");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const host_target = b.standardTargetOptions(.{});
    const device_target = std.zig.CrossTarget.parse(.{
        .arch_os_abi = "amdgcn-amdhsa",
        .cpu_features = "gfx908",
    }) catch unreachable;

    const example = b.addExecutable("zhc-example", "example/main.zig");
    example.setBuildMode(mode);
    example.setTarget(host_target);
    example.addPackage(zhc.build.getHostPkg(b));
    example.install();

    const example_configs = zhc.build.extractKernelConfigs(b, example);

    const example_gfx803 = zhc.build.addDeviceObject(
        b,
        "example/kernel.zig",
        .amdgpu, // TODO: Maybe move to setPlatform function? Then we can detect it if not specified.
        example_configs,
    );
    example_gfx803.setBuildMode(mode);
    example_gfx803.setTarget(device_target);

    const example_offload = zhc.build.addOffloadLibrary(b);
    example_offload.addKernels(example_gfx803);
    example_offload.setTarget(host_target);
    b.default_step.dependOn(&example_offload.step);

    const tests = b.addTest("src/zhc.zig");
    tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&tests.step);
}
