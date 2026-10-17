const std = @import("std");
const mv = @import("multiver.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Everything outside the per-level objects is pinned to baseline so the
    // dispatcher itself runs on the oldest CPU we support.
    const base = b.resolveTargetQuery(.{
        .cpu_arch = target.result.cpu.arch,
        .os_tag = target.result.os.tag,
        .abi = target.result.abi,
        .cpu_model = .baseline,
    });

    const lib = b.addLibrary(.{
        .name = "AcceleratedRecoilingRealtime",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("realtime/exports.zig"),
            .target = base,
            .optimize = optimize,
        }),
    });
    lib.root_module.addImport("multiver", module(b, "multiver.zig", base, optimize));
    addKernels(b, lib, target.result.cpu.arch);
    b.installArtifact(lib);

    if (target.result.cpu.arch != .x86_64) return;

    // Two test binaries: one pinned to the baseline object set, one built for
    // this machine so the higher ISA variants are actually executed. A cross
    // build cannot run its own tests.
    const test_step = b.step("test", "Run the kernel differential tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = testModule(b, base, optimize) })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = testModule(b, b.graph.host, optimize) })).step);
    // The dispatcher probes the CPU once per process; caching the wrong level
    // would execute instructions this CPU cannot run.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module(b, "cpuid.zig", base, optimize) })).step);
}

fn addKernels(b: *std.Build, compile: *std.Build.Step.Compile, arch: std.Target.Cpu.Arch) void {
    const source = b.path("realtime/kernel.zig");
    if (arch == .x86_64) {
        mv.addMultiVersion(b, compile, .{ .source = source });
    } else {
        mv.addSingleVersion(b, compile, .{ .source = source });
    }
}

fn module(b: *std.Build, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
}

fn testModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return module(b, "realtime/kernel_test.zig", target, optimize);
}
