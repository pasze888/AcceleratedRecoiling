const std = @import("std");
pub const cpuid = @import("cpuid.zig");

pub fn exportAll(comptime Module: type, comptime suffix: []const u8) void {
    for (@typeInfo(Module).@"struct".decls) |decl| {
        const f = @field(Module, decl.name);
        if (isCFn(@TypeOf(f))) {
            @export(&f, .{ .name = suffix ++ "_" ++ decl.name });
        }
    }
}

fn isCFn(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"fn" => |f| std.meta.activeTag(f.calling_convention) == std.meta.activeTag(std.builtin.CallingConvention.c),
        else => false,
    };
}

pub fn externForLevel(comptime F: type, comptime level: cpuid.Level, comptime name: []const u8) F {
    return @extern(F, .{ .name = cpuid.suffix[@intFromEnum(level) - 1] ++ "_" ++ name });
}

pub const Options = struct {
    source: std.Build.LazyPath,
    imports: []const std.Build.Module.Import = &.{},
};

pub fn addMultiVersion(b: *std.Build, compile: *std.Build.Step.Compile, options: Options) void {
    const resolved = compile.root_module.resolved_target.?;
    for (cpuid.levels_hi_to_lo) |level| {
        addVariant(b, compile, options, resolved, level, cpuid.suffix[@intFromEnum(level) - 1]);
    }
}

/// Non-x86 targets get a single baseline clone under the x86_64 symbol prefix,
/// so externForLevel and the dispatcher stay shape-identical everywhere. No
/// cpu model is applied: the per-level models are x86-only.
pub fn addSingleVersion(b: *std.Build, compile: *std.Build.Step.Compile, options: Options) void {
    const resolved = compile.root_module.resolved_target.?;
    addVariant(b, compile, options, resolved, null, "x86_64");
}

fn addVariant(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    options: Options,
    resolved: std.Build.ResolvedTarget,
    level: ?cpuid.Level,
    sfx: []const u8,
) void {
    var query = resolved.query;
    if (level) |l| query.cpu_model = .{ .explicit = cpuModelForLevel(l) };
    const isa_target = b.resolveTargetQuery(query);
    const opt = compile.root_module.optimize orelse .Debug;

    const user_mod = b.createModule(.{
        .root_source_file = options.source,
        .target = isa_target,
        .optimize = opt,
        .pic = true,
    });
    for (options.imports) |imp| user_mod.addImport(imp.name, imp.module);

    const wf = b.addWriteFiles();
    const wrapper = wf.add("wrapper.zig", b.fmt(
        \\const m = @import("_src");
        \\const mv = @import("multiver");
        \\comptime {{ mv.exportAll(m, "{s}"); }}
    , .{sfx}));

    const variant_mod = b.createModule(.{
        .root_source_file = wrapper,
        .target = isa_target,
        .optimize = opt,
        .pic = true,
    });
    variant_mod.addImport("multiver", b.createModule(.{ .root_source_file = b.path("multiver.zig"), .target = isa_target }));
    variant_mod.addImport("_src", user_mod);

    compile.root_module.addObject(b.addObject(.{
        .name = b.fmt("mv_{s}", .{sfx}),
        .root_module = variant_mod,
    }));
}

fn cpuModelForLevel(level: cpuid.Level) *const std.Target.Cpu.Model {
    return switch (level) {
        .x86_64 => &std.Target.x86.cpu.x86_64,
        .x86_64_v2 => &std.Target.x86.cpu.x86_64_v2,
        .x86_64_v3 => &std.Target.x86.cpu.x86_64_v3,
        .x86_64_v4 => &std.Target.x86.cpu.x86_64_v4,
    };
}
