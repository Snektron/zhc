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
    example.addPackage(zhc.build.configure(b, "src/zhc.zig", .host));
    example.install();

    const example_devlib = zhc.build.addDeviceLib(
        b,
        "example/kernel.zig",
        "src/zhc.zig",
        device_target,
    );
    example_devlib.setBuildMode(mode);
    b.default_step.dependOn(&example_devlib.step);

    const example_kcx = zhc.build.KernelConfigExtractStep.create(b, example.getOutputSource());
    b.default_step.dependOn(&example_kcx.step);

    const tests = b.addTest("src/zhc.zig");
    tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&tests.step);
}
