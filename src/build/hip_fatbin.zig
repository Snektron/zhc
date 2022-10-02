//! This file implements build logic to construct HIP-compatible fat binaries.
//! The output is an object file which can be linked with a host binary to provide
//! a way to get the device kernels at runtime.

const std = @import("std");
const CrossTarget = std.zig.CrossTarget;
const build = std.build;
const Builder = build.Builder;
const Step = build.Step;
const GeneratedFile = build.GeneratedFile;
const LibExeObjStep = build.LibExeObjStep;

const zhc = @import("../zhc.zig");
const OffloadBundleStep = zhc.build.offload_bundle.OffloadBundleStep;
const DeviceObjectStep = zhc.build.DeviceObjectStep;

pub const HipFatBinStep = struct {
    step: Step,
    bundle_step: *OffloadBundleStep,
    fatbin_step: *LibExeObjStep,

    pub fn create(b: *Builder) *HipFatBinStep {
        const self = b.allocator.create(HipFatBinStep) catch unreachable;
        self.* = .{
            .step = Step.init(.custom, "hip-fat-binary", b.allocator, make),
            .bundle_step = OffloadBundleStep.create(b),
            .fatbin_step = undefined,
        };

        self.step.dependOn(&self.bundle_step.step);
        return self;
    }

    pub fn setHostTarget(self: *HipFatBinStep, target: CrossTarget) void {
        self.bundle_step.setHostTarget(target);
    }

    pub fn add(self: *HipFatBinStep, device_object: *DeviceObjectStep) void {
        self.bundle_step.add(.{
            .offload_kind = .hipv4,
            .object = device_object.object,
        });
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(HipFatBinStep, "step", step);
        _ = self;
    }
};
