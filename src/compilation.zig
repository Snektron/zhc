//! This file contains some information and helpers related to the current
//! compilation.

const std = @import("std");

const zhc = @import("zhc.zig");
const build_options = @import("zhc_build_options");
const platform_build_options = @import("zhc_platform_build_options");

const builtin = @import("builtin");

/// Indicates a side of compilation.
/// The value of this enum for the current build is made visible through
/// `zhc.compilation.side`.
pub const Side = enum {
    /// Indicates "host" code: Code which runs the driver program,
    /// that interfaces with accelerators and launches kernels
    /// (typically the CPU).
    host,
    /// Indicates "device" code: Code which implements actual kernels, and
    /// is meant to run on an accelerator (typically a GPU).
    device,
};

/// The side code is currently being compiled for.
pub const side: Side = build_options.side;

/// The platform which we are currently compiling device code for.
/// Only available on the device side, on host this value is dynamic.
pub const platform: zhc.platform.Kind = blk: {
    deviceOnly();
    break :blk platform_build_options.platform;
};

/// The configurions of kernels to launch.
pub const launch_configurations = blk: {
    deviceOnly();
    // For debugging purposes, just check if all the configurations are generated
    // correctly here.
    const configs = build_options.launch_configurations;
    inline for (std.meta.declarations(configs)) |decl| {
        const config: []const zhc.abi.Overload = @field(configs, decl.name);
        _ = config;
    }

    break :blk configs;
};

/// Ensure that the compilation of a scope is at `required_side`.
/// Produces a compile error otherwise.
pub inline fn sideOnly(comptime required_side: Side) void {
    comptime {
        if (required_side != side) {
            @compileError("cannot compile " ++ @tagName(required_side) ++ " code on " ++ @tagName(side) ++ " side");
        }
    }
}

/// Ensure that the compilation of a scope is targetted at host-side execution.
pub inline fn hostOnly() void {
    sideOnly(.host);
}

/// Ensure that the compilation of a scope is targetted at device-side execution.
pub inline fn deviceOnly() void {
    sideOnly(.device);
}

/// Returns true if we're currently compiling for device-side execution.
pub fn isDevice() bool {
    return side == .device;
}

/// Returns true if we're currently compiling for host-side execution.
pub fn isHost() bool {
    return side == .host;
}
