const std = @import("std");
const builtin = @import("builtin");
const mv = @import("multiver");
const cpuid = mv.cpuid;
const kernel = @import("kernel.zig");
const Section = kernel.Section;
const Query = kernel.Query;

pub const ABI_VERSION: i32 = 11;

/// ISA level requested by the Java side. Ids are the same numeric values the
/// Java Kernel enum uses, so the mapping stays one-to-one and readable.
/// SIMD is an alias for AUTO: the quantized pre-filter is chosen per section
/// inside the kernel, so there is no separate "force the double path" kernel.
pub const Kernel = enum(i32) {
    simd = -2,
    auto = -1,
    scalar = 0,
    v1 = 1,
    v2 = 2,
    v3 = 3,
    v4 = 4,

    fn level(self: Kernel) i32 {
        return switch (self) {
            .v1 => 1,
            .v2 => 2,
            .v3 => 3,
            .v4 => 4,
            else => 0,
        };
    }
};

/// Highest level this build linked in. This module is the pinned-baseline
/// dispatcher, so its own cpu.features say nothing about the variant objects;
/// on x86_64 build.zig always emits all four, and elsewhere exactly one
/// baseline clone.
fn buildLevel() i32 {
    return if (builtin.cpu.arch == .x86_64) 4 else 1;
}

/// Highest level this CPU and OS can execute, capped by what was compiled in.
fn cpuLevel() i32 {
    const compiled = buildLevel();
    if (compiled == 1) return 1;
    const detected = cpuid.detect() orelse return 1;
    return @min(compiled, @intFromEnum(detected));
}

/// Level to execute for a kernel, clamped so e.g. a requested v4 on a v3 build
/// runs the v3 object instead of an unsupported instruction.
fn useLevel(k: Kernel) i32 {
    if (k == .scalar) return 0;
    return @min(k.level(), cpuLevel());
}

pub export fn ar_version() i32 {
    return ABI_VERSION;
}

pub export fn ar_quantizationMinEntities() i32 {
    return kernel.MIN_QUANTIZED_ENTITIES;
}

pub export fn ar_selectKernel(requested: i32) i32 {
    if (requested < @intFromEnum(Kernel.simd) or requested > @intFromEnum(Kernel.v4)) return -1;
    var wanted: Kernel = @enumFromInt(requested);
    if (wanted == .auto or wanted == .simd) wanted = bestKernel();
    // Refuse a level this CPU or build cannot run rather than silently
    // downgrading; the Java side treats -1 as failure and falls back to vanilla.
    if (wanted != .scalar and wanted.level() > cpuLevel()) return -1;
    chosen = wanted;
    return @intFromEnum(wanted);
}

fn bestKernel() Kernel {
    return switch (cpuLevel()) {
        4 => .v4,
        3 => .v3,
        2 => .v2,
        else => .v1,
    };
}

var chosen: Kernel = .scalar;

pub export fn ar_queryBatch(
    sections: ?[*]const Section,
    section_count: i32,
    output: ?[*]i64,
    sections_bytes: i64,
    output_bytes: i64,
    source_section: i32,
    source_slot: i32,
    source_x: f64,
    source_z: f64,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
    retain_collisions: bool,
) i64 {
    const plan = sections orelse return -2;
    const out = output orelse return -2;
    if (section_count < 0) return -2;
    if (@as(i64, section_count) * @sizeOf(Section) > sections_bytes) return -2;

    var entry_count: i64 = 0;
    for (0..@as(usize, @intCast(section_count))) |s| {
        if (plan[s].address == 0 or plan[s].count < 0 or plan[s].stride < plan[s].count) return -2;
        entry_count += plan[s].count;
    }
    if (entry_count > std.math.maxInt(i32)) return -2;
    if (entry_count * kernel.OUTPUT_FIELDS * @sizeOf(i64) > output_bytes) return -2;

    const query = Query{
        .bounds = .{ min_x, min_y, min_z, max_x, max_y, max_z },
        .x = source_x,
        .z = source_z,
        .source_section = source_section,
        .source_slot = source_slot,
        .retain_collisions = retain_collisions,
    };

    return dispatch(chosen, plan, section_count, @intCast(entry_count), out, &query);
}

fn dispatch(k: Kernel, sections: [*]const Section, section_count: i32, entries: i32, output: [*]i64, q: *const Query) i64 {
    const level = useLevel(k);
    if (level == 0) {
        return switch (cpuLevel()) {
            4 => scalarVariant(.x86_64_v4, sections, section_count, entries, output, q),
            3 => scalarVariant(.x86_64_v3, sections, section_count, entries, output, q),
            2 => scalarVariant(.x86_64_v2, sections, section_count, entries, output, q),
            else => scalarVariant(.x86_64, sections, section_count, entries, output, q),
        };
    }

    return switch (level) {
        4 => mv.externForLevel(BatchFn, .x86_64_v4, "batch")(sections, section_count, entries, output, q),
        3 => mv.externForLevel(BatchFn, .x86_64_v3, "batch")(sections, section_count, entries, output, q),
        2 => mv.externForLevel(BatchFn, .x86_64_v2, "batch")(sections, section_count, entries, output, q),
        else => mv.externForLevel(BatchFn, .x86_64, "batch")(sections, section_count, entries, output, q),
    };
}

const BatchFn = *const fn ([*]const Section, i32, i32, [*]i64, *const Query) callconv(.c) i64;
const ScalarFn = *const fn ([*]const Section, i32, i32, [*]i64, *const Query) callconv(.c) i64;

fn scalarVariant(comptime level: cpuid.Level, sections: [*]const Section, section_count: i32, entries: i32, output: [*]i64, q: *const Query) i64 {
    return mv.externForLevel(ScalarFn, level, "scalar")(sections, section_count, entries, output, q);
}
