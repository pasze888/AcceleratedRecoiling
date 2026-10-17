const std = @import("std");
const builtin = @import("builtin");
const spatial = @import("spatial.zig");
const SpatialIndex = spatial.SpatialIndex;
const SpatialQuery = spatial.SpatialQuery;

pub const SCALE = 64.0;
pub const MIN_QUANTIZED_ENTITIES = 1024;

pub const BOUNDS_MIN_X = 0;
pub const BOUNDS_MIN_Y = 1;
pub const BOUNDS_MIN_Z = 2;
pub const BOUNDS_MAX_X = 3;
pub const BOUNDS_MAX_Y = 4;
pub const BOUNDS_MAX_Z = 5;
pub const POS_X = 6;
pub const POS_Z = 7;
pub const FLAGS = 8;
pub const QUANTIZED_BOXES = 9;

pub const OUTPUT_FIELDS = 2;
pub const PUSH_TARGETS = 1;

/// Mirrors the Java descriptor layout written by BatchedCollisions (32 bytes).
pub const Section = extern struct {
    address: i64,
    count: i32,
    stride: i32,
    spatial: ?*const SpatialIndex,
    coincident: ?[*]const u64,

    comptime {
        std.debug.assert(@sizeOf(Section) == 32);
    }
};

pub const Query = extern struct {
    bounds: [6]f64,
    x: f64,
    z: f64,
    source_section: i32,
    source_slot: i32,
    retain_collisions: bool,
};

pub inline fn quantize(value: f64) i32 {
    const scaled = @floor(value * SCALE);
    if (scaled <= std.math.minInt(i32)) return std.math.minInt(i32);
    if (scaled >= std.math.maxInt(i32)) return std.math.maxInt(i32);
    return if (std.math.isNan(scaled)) 0 else @intFromFloat(scaled);
}

pub fn quantizeBox(bounds: *const [6]f64, result: *[6]i32) void {
    for (BOUNDS_MIN_X..BOUNDS_MAX_Z + 1) |field| {
        if (std.math.isFinite(bounds[field])) continue;
        for (BOUNDS_MIN_X..BOUNDS_MAX_Z + 1) |bound| {
            result[bound] = if (bound < BOUNDS_MAX_X) std.math.minInt(i32) else std.math.maxInt(i32);
        }
        return;
    }
    for (BOUNDS_MIN_X..BOUNDS_MAX_Z + 1) |field| {
        result[field] = quantize(bounds[field]);
    }
}

inline fn intersects(data: [*]const f64, stride: usize, slot: usize, bounds: *const [6]f64) bool {
    return data[BOUNDS_MIN_X * stride + slot] < bounds[BOUNDS_MAX_X]
        and data[BOUNDS_MAX_X * stride + slot] > bounds[BOUNDS_MIN_X]
        and data[BOUNDS_MIN_Y * stride + slot] < bounds[BOUNDS_MAX_Y]
        and data[BOUNDS_MAX_Y * stride + slot] > bounds[BOUNDS_MIN_Y]
        and data[BOUNDS_MIN_Z * stride + slot] < bounds[BOUNDS_MAX_Z]
        and data[BOUNDS_MAX_Z * stride + slot] > bounds[BOUNDS_MIN_Z];
}

/// Scalar reference. Returns false when the caller must fall back to vanilla
/// collision handling (negative flag or a non-finite position).
fn scalarCandidate(
    data: [*]const f64,
    stride: usize,
    section: i32,
    slot: usize,
    entries: usize,
    output: [*]i64,
    q: *const Query,
    comptime retain: bool,
    selected: *i32,
    nonzero: *i32,
) bool {
    if (q.source_slot >= 0 and section == q.source_section and slot == @as(usize, @intCast(q.source_slot))) {
        return true;
    }
    if (!intersects(data, stride, slot, &q.bounds)) return true;

    const flag = data[FLAGS * stride + slot];
    if (flag < 0) return false;
    if (flag == 0) return true;

    const x = data[POS_X * stride + slot];
    const z = data[POS_Z * stride + slot];
    if (!std.math.isFinite(x) or !std.math.isFinite(z)) return false;

    const hit = hitId(section, slot);
    if (retain) output[@intCast(selected.*)] = hit;
    selected.* += 1;

    const push_threshold: f64 = @floatCast(@as(f32, 0.01));
    if (@abs(q.x - x) >= push_threshold or @abs(q.z - z) >= push_threshold) {
        output[PUSH_TARGETS * entries + @as(usize, @intCast(nonzero.*))] = hit;
        nonzero.* += 1;
    }
    return true;
}

fn scalarBatch(
    plan: [*]const Section,
    section_count: usize,
    entries: usize,
    output: [*]i64,
    q: *const Query,
    comptime retain: bool,
) i64 {
    var selected: i32 = 0;
    var nonzero: i32 = 0;
    for (0..section_count) |s| {
        const data: [*]const f64 = @ptrFromInt(@as(usize, @intCast(plan[s].address)));
        const stride: usize = @intCast(plan[s].stride);
        for (0..@as(usize, @intCast(plan[s].count))) |i| {
            if (!scalarCandidate(data, stride, @intCast(s), i, entries, output, q, retain, &selected, &nonzero)) {
                return -1;
            }
        }
    }
    return (@as(i64, selected) << 32) | @as(u32, @bitCast(nonzero));
}

inline fn hitId(section: i32, slot: usize) i64 {
    return (@as(i64, section) << 32) | @as(u32, @truncate(slot));
}

// ---------------------------------------------------------------------------
// Vector path
// ---------------------------------------------------------------------------

const DLANES = 8;
const ILANES = 16;
const Vd = @Vector(DLANES, f64);
const Vi = @Vector(ILANES, i32);

/// Planes are stride-separated, so every vector load is addressed individually.
inline fn loadD(data: [*]const f64, index: usize) Vd {
    return data[index..][0..DLANES].*;
}

inline fn loadI(data: [*]const i32, index: usize) Vi {
    return data[index..][0..ILANES].*;
}

inline fn compressStore(output: [*]i64, first: i64, mask: u64) void {
    var n: usize = 0;
    inline for (0..DLANES) |lane| {
        if ((mask >> lane) & 1 != 0) {
            output[n] = first + lane;
            n += 1;
        }
    }
}

fn indexedSection(
    section: *const Section,
    section_index: i32,
    entry_count: usize,
    output: [*]i64,
    q: *const Query,
    quantized_bounds: *const [6]i32,
    comptime retain: bool,
    collision_count: *i32,
    push_count: *i32,
) bool {
    const index = section.spatial.?;
    const data: [*]const f64 = @ptrFromInt(@as(usize, @intCast(section.address)));
    const stride: usize = @intCast(section.stride);
    const count: usize = @intCast(section.count);
    const sq = SpatialQuery.init(index, quantized_bounds);
    const eligible = index.entityBitmap(.eligible);
    const fallback = index.entityBitmap(.fallback);

    var word_index: usize = 0;
    while (word_index < (count + 63) / 64) : (word_index += 1) {
        var candidate_mask = sq.candidates(word_index);

        if (section_index == q.source_section and q.source_slot >= 0) {
            const source_word: usize = @intCast(@divTrunc(q.source_slot, 64));
            if (source_word == word_index) {
                candidate_mask &= ~(@as(u64, 1) << @intCast(@mod(q.source_slot, 64)));
            }
        }

        candidate_mask &= eligible[word_index] | fallback[word_index];
        var pending = candidate_mask;
        var collision_mask: u64 = 0;

        while (pending != 0) {
            const bit: u6 = @intCast(@ctz(pending));
            const slot = word_index * 64 + @as(usize, bit);
            pending &= pending - 1;
            if (intersects(data, stride, slot, &q.bounds)) {
                collision_mask |= @as(u64, 1) << bit;
            }
        }

        if (collision_mask & fallback[word_index] != 0) return false;

        if (retain) {
            var remaining = collision_mask;
            while (remaining != 0) {
                const bit: u6 = @intCast(@ctz(remaining));
                remaining &= remaining - 1;
                output[@intCast(collision_count.*)] = hitId(section_index, word_index * 64 + @as(usize, bit));
                collision_count.* += 1;
            }
        } else {
            collision_count.* += @popCount(collision_mask);
        }

        const coincident_word: u64 = if (section.coincident) |c| c[word_index] else 0;
        var push_mask = collision_mask & ~coincident_word;
        while (push_mask != 0) {
            const bit: u6 = @intCast(@ctz(push_mask));
            push_mask &= push_mask - 1;
            const slot = word_index * 64 + @as(usize, bit);
            const dx = q.x - data[POS_X * stride + slot];
            const dz = q.z - data[POS_Z * stride + slot];
            const push_threshold: f64 = @floatCast(@as(f32, 0.01));
            if (@abs(dx) < push_threshold and @abs(dz) < push_threshold) continue;
            output[PUSH_TARGETS * entry_count + @as(usize, @intCast(push_count.*))] = hitId(section_index, slot);
            push_count.* += 1;
        }
    }
    return true;
}

fn vectorBatch(
    sections: [*]const Section,
    section_count: usize,
    entry_count: usize,
    output: [*]i64,
    q: *const Query,
    comptime retain: bool,
) i64 {
    const query_min_x: Vd = @splat(q.bounds[BOUNDS_MIN_X]);
    const query_min_y: Vd = @splat(q.bounds[BOUNDS_MIN_Y]);
    const query_min_z: Vd = @splat(q.bounds[BOUNDS_MIN_Z]);
    const query_max_x: Vd = @splat(q.bounds[BOUNDS_MAX_X]);
    const query_max_y: Vd = @splat(q.bounds[BOUNDS_MAX_Y]);
    const query_max_z: Vd = @splat(q.bounds[BOUNDS_MAX_Z]);
    const source_x: Vd = @splat(q.x);
    const source_z: Vd = @splat(q.z);
    const push_threshold: Vd = @splat(@as(f64, @floatCast(@as(f32, 0.01))));
    const zero: Vd = @splat(0.0);

    var quantized_query: [6]i32 = undefined;
    quantizeBox(&q.bounds, &quantized_query);
    const q_min_x: Vi = @splat(quantized_query[BOUNDS_MIN_X]);
    const q_min_y: Vi = @splat(quantized_query[BOUNDS_MIN_Y]);
    const q_min_z: Vi = @splat(quantized_query[BOUNDS_MIN_Z]);
    const q_max_x: Vi = @splat(quantized_query[BOUNDS_MAX_X]);
    const q_max_y: Vi = @splat(quantized_query[BOUNDS_MAX_Y]);
    const q_max_z: Vi = @splat(quantized_query[BOUNDS_MAX_Z]);
    const sentinel: Vi = @splat(std.math.minInt(i32));

    var collision_count: i32 = 0;
    var push_count: i32 = 0;

    for (0..section_count) |section| {
        const current = &sections[section];
        if (current.spatial != null and current.coincident != null) {
            if (!indexedSection(current, @intCast(section), entry_count, output, q, &quantized_query, retain, &collision_count, &push_count)) {
                return -1;
            }
            continue;
        }

        const stride: usize = @intCast(current.stride);
        const count: usize = @intCast(current.count);
        const data: [*]const f64 = @ptrFromInt(@as(usize, @intCast(current.address)));
        const quantized_boxes: [*]const i32 = @ptrCast(@alignCast(data + QUANTIZED_BOXES * stride));
        const use_quantization = count >= MIN_QUANTIZED_ENTITIES;
        const source_slot: i64 = if (@as(i64, @intCast(section)) == q.source_section) q.source_slot else -1;

        var spatial_query: ?SpatialQuery = null;
        if (current.spatial) |index| spatial_query = SpatialQuery.init(index, &quantized_query);
        const eligible = if (current.spatial) |index| index.entityBitmap(.eligible) else null;
        const fallback = if (current.spatial) |index| index.entityBitmap(.fallback) else null;
        var candidate_word: u64 = 0;

        var block_start: usize = 0;
        while (block_start + ILANES <= count) : (block_start += ILANES) {
            var candidate_mask: u32 = 0xffff;
            // Only the quantized pre-filter can confirm an overlap without the
            // f64 test; the spatial path now exact-tests every candidate.
            var confirmed_mask: u32 = 0;

            if (spatial_query) |*sq| {
                const bit_offset: u5 = @intCast(block_start % 64);
                if (bit_offset == 0) {
                    const word = block_start / 64;
                    candidate_word = sq.candidates(word);
                    candidate_word &= eligible.?[word] | fallback.?[word];
                }
                candidate_mask = @as(u32, @truncate(candidate_word >> bit_offset)) & 0xffff;
                if (candidate_mask == 0) continue;
            } else if (use_quantization) {
                const c_min_x = loadI(quantized_boxes, BOUNDS_MIN_X * stride + block_start);
                const c_min_y = loadI(quantized_boxes, BOUNDS_MIN_Y * stride + block_start);
                const c_min_z = loadI(quantized_boxes, BOUNDS_MIN_Z * stride + block_start);
                const c_max_x = loadI(quantized_boxes, BOUNDS_MAX_X * stride + block_start);
                const c_max_y = loadI(quantized_boxes, BOUNDS_MAX_Y * stride + block_start);
                const c_max_z = loadI(quantized_boxes, BOUNDS_MAX_Z * stride + block_start);

                const outside = (c_min_x > q_max_x) | (q_min_x > c_max_x)
                    | (c_min_y > q_max_y) | (q_min_y > c_max_y)
                    | (c_min_z > q_max_z) | (q_min_z > c_max_z);
                candidate_mask &= ~maskBits(outside);
                if (candidate_mask == 0) continue;

                const boundary = (c_min_x == q_max_x) | (q_min_x == c_max_x)
                    | (c_min_y == q_max_y) | (q_min_y == c_max_y)
                    | (c_min_z == q_max_z) | (q_min_z == c_max_z);
                confirmed_mask = candidate_mask & ~(maskBits(boundary) | maskBits(c_min_x == sentinel));
            }

            if (source_slot >= 0 and source_slot >= block_start and source_slot < block_start + ILANES) {
                candidate_mask &= ~(@as(u32, 1) << @intCast(@as(usize, @intCast(source_slot)) - block_start));
            }

            var lane_offset: usize = 0;
            while (lane_offset < ILANES) : (lane_offset += DLANES) {
                const first_slot = block_start + lane_offset;
                var collision_mask: u32 = (candidate_mask >> @intCast(lane_offset)) & 0xff;
                if (collision_mask == 0) continue;

                const confirmed_collisions = (confirmed_mask >> @intCast(lane_offset)) & collision_mask;
                if (collision_mask != confirmed_collisions) {
                    const overlap_x = (loadD(data, BOUNDS_MIN_X * stride + first_slot) < query_max_x) &
                        (query_min_x < loadD(data, BOUNDS_MAX_X * stride + first_slot));
                    const overlap_y = (loadD(data, BOUNDS_MIN_Y * stride + first_slot) < query_max_y) &
                        (query_min_y < loadD(data, BOUNDS_MAX_Y * stride + first_slot));
                    const overlap_z = (loadD(data, BOUNDS_MIN_Z * stride + first_slot) < query_max_z) &
                        (query_min_z < loadD(data, BOUNDS_MAX_Z * stride + first_slot));
                    collision_mask = confirmed_collisions | (collision_mask & maskBits4(overlap_x & overlap_y & overlap_z));
                }
                if (collision_mask == 0) continue;

                const flags = loadD(data, FLAGS * stride + first_slot);
                if (collision_mask & maskBits4(flags < zero) != 0) return -1;
                collision_mask &= ~maskBits4(flags == zero);
                if (collision_mask == 0) continue;

                const candidate_x = loadD(data, POS_X * stride + first_slot);
                const candidate_z = loadD(data, POS_Z * stride + first_slot);
                const max_finite: Vd = @splat(std.math.floatMax(f64));
                const finite_position = (@abs(candidate_x) <= max_finite) & (@abs(candidate_z) <= max_finite);
                if (collision_mask & ~maskBits4(finite_position) != 0) return -1;

                const push_mask = collision_mask & maskBits4(
                    (push_threshold <= @abs(source_x - candidate_x)) | (push_threshold <= @abs(source_z - candidate_z)),
                );

                const first_hit = hitId(@intCast(section), first_slot);
                if (retain) compressStore(output + @as(usize, @intCast(collision_count)), first_hit, collision_mask);
                collision_count += @popCount(collision_mask);

                if (push_mask == 0) continue;
                compressStore(output + entry_count + @as(usize, @intCast(push_count)), first_hit, push_mask);
                push_count += @popCount(push_mask);
            }
        }

        var slot = block_start;
        while (slot < count) : (slot += 1) {
            if (!scalarCandidate(data, stride, @intCast(section), slot, entry_count, output, q, retain, &collision_count, &push_count)) {
                return -1;
            }
        }
    }

    return (@as(i64, collision_count) << 32) | @as(u32, @bitCast(push_count));
}

/// Bool-vector -> bitmask. Zig only bitcasts bool vectors to integers of the
/// exact same bit width, so the 16-lane block mask widens from u16.
inline fn maskBits(mask: @Vector(ILANES, bool)) u32 {
    const bits: u16 = @bitCast(mask);
    return bits;
}

inline fn maskBits4(mask: @Vector(DLANES, bool)) u32 {
    const bits: u8 = @bitCast(mask);
    return bits;
}

// ---------------------------------------------------------------------------
// Entry points. multiver.exportAll re-exports these once per ISA level as
// <level>_batch / <level>_scalar; exports.zig picks one at runtime.
// ---------------------------------------------------------------------------

pub fn scalar(
    sections: [*]const Section,
    section_count: i32,
    entries: i32,
    output: [*]i64,
    q: *const Query,
) callconv(.c) i64 {
    if (!std.math.isFinite(q.x) or !std.math.isFinite(q.z)) return -1;
    const count: usize = @intCast(section_count);
    const entry_count: usize = @intCast(entries);
    return if (q.retain_collisions)
        scalarBatch(sections, count, entry_count, output, q, true)
    else
        scalarBatch(sections, count, entry_count, output, q, false);
}

/// The quantized pre-filter is applied per section, exactly like the C++
/// runtime: sections shallower than MIN_QUANTIZED_ENTITIES take the double
/// path. "quantized" in the old kernel names therefore selects nothing.
pub fn batch(
    sections: [*]const Section,
    section_count: i32,
    entries: i32,
    output: [*]i64,
    q: *const Query,
) callconv(.c) i64 {
    if (!std.math.isFinite(q.x) or !std.math.isFinite(q.z)) return -1;
    for (q.bounds) |bound| {
        if (!std.math.isFinite(bound)) return scalar(sections, section_count, entries, output, q);
    }

    const count: usize = @intCast(section_count);
    const entry_count: usize = @intCast(entries);
    if (q.retain_collisions) {
        return vectorBatch(sections, count, entry_count, output, q, true);
    }
    return vectorBatch(sections, count, entry_count, output, q, false);
}
