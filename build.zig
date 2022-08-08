const std = @import("std");
const zhc = @import("src/zhc.zig");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const example = b.addExecutable("zhc-example", "example/main.zig");
    example.setBuildMode(mode);
    example.setTarget(target);
    example.addPackage(zhc.build.configure(b, "src/zhc.zig", .host));
    example.install();

    const device_target = std.zig.CrossTarget.parse(.{
        .arch_os_abi = "amdgcn-amdhsa",
        .cpu_features = "gfx908",
    }) catch unreachable;

    const example_devlib = zhc.build.addDeviceLib(
        b,
        "example/kernel.zig",
        "src/zhc.zig",
        device_target,
    );
    b.default_step.dependOn(&example_devlib.step);

    const lib_tests = b.addTest("src/zhc.zig");
    lib_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&lib_tests.step);
}
