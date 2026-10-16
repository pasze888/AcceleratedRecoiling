const std = @import("std");
const builtin = @import("builtin");

pub const Level = enum(u8) { x86_64 = 1, x86_64_v2 = 2, x86_64_v3 = 3, x86_64_v4 = 4 };
pub const suffix = [_][]const u8{ "x86_64", "x86_64_v2", "x86_64_v3", "x86_64_v4" };
pub const levels_hi_to_lo = [_]Level{ .x86_64_v4, .x86_64_v3, .x86_64_v2, .x86_64 };

fn cpuid(leaf: u32, sub: u32) [4]u32 {
    if (builtin.cpu.arch != .x86_64) unreachable;
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ a, b, c, d };
}

fn xgetbv0() u64 {
    if (builtin.cpu.arch != .x86_64) unreachable;
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("xgetbv" : [lo] "={eax}" (lo), [hi] "={edx}" (hi) : [c] "{ecx}" (@as(u32, 0)));
    return (@as(u64, hi) << 32) | lo;
}

fn hasAvxState() bool {
    const l1 = cpuid(1, 0);
    if ((l1[2] & (1 << 27)) == 0) return false; // OSXSAVE
    if ((l1[2] & (1 << 28)) == 0) return false; // AVX
    return (xgetbv0() & 0x6) == 0x6;
}

/// Highest x86-64-vN the running CPU and OS can execute, or null when the host
/// has no vector path at all (non-x86, or x86 without the v2 baseline).
pub fn detect() ?Level {
    if (builtin.cpu.arch != .x86_64) return null;
    const l1 = cpuid(1, 0);
    const v2_features = (1 << 13) | (1 << 20) | (1 << 23); // CX16, SSE4.2, POPCNT
    if ((l1[2] & v2_features) != v2_features) return null;
    if (!hasAvxState()) return .x86_64_v2;

    const max_leaf = cpuid(0, 0)[0];
    if (max_leaf < 7) return .x86_64_v2;
    const l7 = cpuid(7, 0);

    // AVX-512 F + DQ + CD + BW + VL, plus the OS-enabled opmask/zmm state.
    const need512: u32 = (1 << 16) | (1 << 17) | (1 << 28) | (1 << 30) | (1 << 31);
    if ((xgetbv0() & 0xe6) == 0xe6 and (l7[1] & need512) == need512) return .x86_64_v4;
    return if ((l7[1] & (1 << 5)) != 0) .x86_64_v3 else .x86_64_v2;
}
