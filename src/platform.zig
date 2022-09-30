//! In this file the basic backend types that are supported by ZHC are declared.

/// This enum describes the possible platforms that we can target.
pub const Kind = enum {
    /// This platform targets AMD GPUs, and tries to be in some way compatible
    /// with HIP/ROCm.
    amdgpu,

    // TODO: Nvidia
    // TODO: Host ?
};
