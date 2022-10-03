//! This file declares various utilities that dont have another clear place to go.

const std = @import("std");

pub const msgpack = @import("util/msgpack.zig");

/// Remove a particular prefix from a string, and return
/// an optional with the result value if the string did
/// indeed start with that prefix
pub fn removePrefix(str: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, str, prefix)) {
        return str[prefix.len..];
    }

    return null;
}
