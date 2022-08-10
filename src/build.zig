//! Build-integration is exported here. When using ZHC build options,
//! it is advised to not use any functionality outside this path.

const std = @import("std");
const zhc = @import("zhc.zig");

const elf = std.elf;
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
            @alignOf(elf.Elf64_Ehdr),
            null,
        );
        const header = try elf.Header.parse(elf_bytes[0..@sizeOf(elf.Elf64_Ehdr)]);

        switch (header.is_64) {
            true => switch (header.endian) {
                .Big => try parseElf(header, elf_bytes, true, .Big),
                .Little => try parseElf(header, elf_bytes, true, .Little),
            },
            false => switch (header.endian) {
                .Big => try parseElf(header, elf_bytes, false, .Big),
                .Little => try parseElf(header, elf_bytes, false, .Little),
            },
        }
    }

    fn parseElf(
        header: elf.Header,
        elf_bytes: []const u8,
        comptime is_64: bool,
        comptime endian: std.builtin.Endian,
    ) !void {
        const Sym = if (is_64) elf.Elf64_Sym else elf.Elf32_Sym;
        const Shdr = if (is_64) elf.Elf64_Shdr else elf.Elf32_Shdr;
        const S = struct {
            fn endianSwap(x: anytype) @TypeOf(x) {
                if (endian != native_endian) {
                    return @byteSwap(@TypeOf(x), x);
                } else {
                    return x;
                }
            }
            fn symbolAddrLessThan(_: void, lhs: Sym, rhs: Sym) bool {
                return endianSwap(lhs.st_value) < endianSwap(rhs.st_value);
            }
        };
        // A little helper to do endian swapping.
        const s = S.endianSwap;

        const shdrs = std.mem.bytesAsSlice(Shdr, elf_bytes[header.shoff..])[0..header.shnum];
        const shstrtab_offset = s(shdrs[header.shstrndx].sh_offset);
        const shstrtab = elf_bytes[shstrtab_offset..];

        // Find offsets of the .symtab table.
        const symtab_index = for (shdrs) |shdr, i| {
            const sh_name = std.mem.sliceTo(shstrtab[s(shdr.sh_name)..], 0);
            if (std.mem.eql(u8, sh_name, ".symtab")) {
                break @intCast(u16, i);
            }
        } else {
            std.log.err("object has no .symtab section", .{});
            return error.NoSymtab;
        };

        const strtab_offset = s(shdrs[s(shdrs[symtab_index].sh_link)].sh_offset);
        const strtab = elf_bytes[strtab_offset..];

        const syms_off = s(shdrs[symtab_index].sh_offset);
        const syms_size = s(shdrs[symtab_index].sh_size);
        const syms = std.mem.bytesAsSlice(Sym, elf_bytes[syms_off..][0..syms_size]);

        for (syms) |sym| {
            const name = std.mem.sliceTo(strtab[s(sym.st_name)..], 0);
            if (!std.mem.startsWith(u8, name, zhc.abi.kernel_array_sym_prefix)) {
                continue;
            }
            std.debug.print("kernel configuration: {s}\n", .{name});
        }
    }
};
