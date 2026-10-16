//! Differential tests for the collision kernel.
//!
//! The scalar routine is the oracle: every vector/quantized/spatial path must
//! produce byte-identical output for it, including the untouched guard words
//! around the output buffer.

const std = @import("std");
const kernel = @import("kernel.zig");
const spatial = @import("spatial.zig");

const Section = kernel.Section;
const Query = kernel.Query;
const SpatialIndex = spatial.SpatialIndex;
const MINQ = kernel.MIN_QUANTIZED_ENTITIES;
const sentinel: i64 = 0x1937562840293746;

const Input = struct {
    allocator: std.mem.Allocator,
    count: i32,
    stride: i32,
    words: []f64,

    fn init(allocator: std.mem.Allocator, size: i32, padding: i32) !Input {
        const stride = @max(1, size + padding);
        const planes: usize = if (size >= MINQ) 12 else 9;
        return .{
            .allocator = allocator,
            .count = size,
            .stride = stride,
            .words = try allocator.alloc(f64, planes * @as(usize, @intCast(stride))),
        };
    }

    fn deinit(self: *Input) void {
        self.allocator.free(self.words);
    }

    fn quantizedBoxes(self: *Input) [*]i32 {
        return @ptrCast(@alignCast(self.words.ptr + kernel.QUANTIZED_BOXES * @as(usize, @intCast(self.stride))));
    }

    fn put(self: *Input, slot: usize, box: [6]f64, x: f64, z: f64, flag: f64) void {
        const stride: usize = @intCast(self.stride);
        for (0..6) |plane| self.words[plane * stride + slot] = box[plane];
        self.words[kernel.POS_X * stride + slot] = x;
        self.words[kernel.POS_Z * stride + slot] = z;
        self.words[kernel.FLAGS * stride + slot] = flag;
        if (self.count < MINQ) return;
        var quantized: [6]i32 = undefined;
        kernel.quantizeBox(&box, &quantized);
        const boxes = self.quantizedBoxes();
        for (0..6) |plane| boxes[plane * stride + slot] = quantized[plane];
    }

    fn remove(self: *Input, slot: usize) void {
        const stride: usize = @intCast(self.stride);
        for (0..6) |field| {
            const minimum = field < kernel.BOUNDS_MAX_X;
            self.words[field * stride + slot] = if (minimum) std.math.inf(f64) else -std.math.inf(f64);
            if (self.count >= MINQ) {
                const boxes = self.quantizedBoxes();
                boxes[field * stride + slot] = if (minimum) std.math.maxInt(i32) else std.math.minInt(i32);
            }
        }
    }

    fn section(self: *Input) Section {
        return .{
            .address = @intCast(@intFromPtr(self.words.ptr)),
            .count = self.count,
            .stride = self.stride,
            .spatial = null,
            .coincident = null,
        };
    }
};

var checks: usize = 0;

/// Compares the scalar oracle against both vector entry points for one case.
fn check(allocator: std.mem.Allocator, inputs: []Input, query: Query, case_number: usize) !void {
    const sections = try allocator.alloc(Section, inputs.len);
    defer allocator.free(sections);
    var count: usize = 0;
    for (inputs, 0..) |*input, i| {
        sections[i] = input.section();
        count += @intCast(input.count);
    }

    for ([_]bool{ true, false }) |retain| {
        var requested = query;
        requested.retain_collisions = retain;
        const output_words = count * kernel.OUTPUT_FIELDS;
        const reference = try allocator.alloc(i64, output_words + 4);
        defer allocator.free(reference);
        const observed = try allocator.alloc(i64, output_words + 4);
        defer allocator.free(observed);

        @memset(reference, sentinel);
        const expected = kernel.scalar(sections.ptr, @intCast(sections.len), @intCast(count), reference.ptr + 2, &requested);

        @memset(observed, sentinel);
        const result = kernel.batch(sections.ptr, @intCast(sections.len), @intCast(count), observed.ptr + 2, &requested);

        // The quantized pre-filter turns itself on per section at MINQ, so the
        // generated cases must exercise both sides of that threshold.
        const guards = observed[0] == sentinel and observed[1] == sentinel and
            observed[output_words + 2] == sentinel and observed[output_words + 3] == sentinel;
        var unused_half = true;
        if (!retain) {
            for (observed[2 .. count + 2]) |value| {
                if (value != sentinel) unused_half = false;
            }
        }
        const match = result < 0 or std.mem.eql(i64, reference, observed);
        if (result != expected or !match or !guards or !unused_half) {
            std.debug.print("mismatch case={d} retain={} scalar={d} vector={d}\n", .{ case_number, retain, expected, result });
            return error.Mismatch;
        }
        checks += 1;
    }
}

fn checkQuantizedBox(bounds: [6]f64, expected: [6]i32) !void {
    var result: [6]i32 = @splat(123456789);
    kernel.quantizeBox(&bounds, &result);
    try std.testing.expectEqual(expected, result);
}

test "box quantization saturates and rejects non-finite input" {
    const bounds = [6]f64{ -1.01, -0.01, -0.0, 1.01, 0.01, 2.5 };
    const full: [6]i32 = .{ std.math.minInt(i32), std.math.minInt(i32), std.math.minInt(i32), std.math.maxInt(i32), std.math.maxInt(i32), std.math.maxInt(i32) };

    try checkQuantizedBox(bounds, .{ -65, -1, 0, 64, 0, 160 });
    try checkQuantizedBox(.{ -1e100, -1e308, -33554432, 1e100, 1e308, 33554432 }, full);
    try checkQuantizedBox(.{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64), std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) }, full);

    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |invalid| {
        for (0..6) |field| {
            var broken = bounds;
            broken[field] = invalid;
            try checkQuantizedBox(broken, full);
        }
    }
}

const special_values = [_]f64{
    0.0,                -0.0,                    1.0 / kernel.SCALE,    -1.0 / kernel.SCALE,
    0.01,               0.01,                    -0.01,                 29999999.99,
    -29999999.99,       33554432.0,              -33554432.0,           1e100,
    -1e100,             std.math.floatMax(f64),  -std.math.floatMax(f64), std.math.inf(f64),
    -std.math.inf(f64), std.math.nan(f64),       std.math.floatMin(f64),
};
const push_threshold: f64 = @floatCast(@as(f32, 0.01));

fn randomPosition(random: std.Random) f64 {
    return @as(f64, @floatFromInt(@as(i64, @intCast(random.uintLessThan(u32, 512))) - 256)) / kernel.SCALE;
}

fn specialCoordinate(random: std.Random) f64 {
    return special_values[random.uintLessThan(usize, special_values.len)];
}

fn sectionSize(random: std.Random, case_index: usize, section_index: usize) i32 {
    if (case_index < 200) return @intCast(case_index % 70);
    if ((case_index + section_index) % 4 == 1) return @intCast(MINQ - 1 + random.uintLessThan(u32, 67));
    return @intCast(random.uintLessThan(u32, 100));
}

fn fillSection(random: std.Random, input: *Input, query: *const Query, origin: f64, case_index: usize) void {
    const grid_positions = case_index % 2 == 0;
    const special_bounds = case_index % 13 == 0;
    const special_positions = case_index % 17 == 0;
    const near_push_threshold = case_index % 19 == 0;
    const include_callbacks = case_index % 7 == 0;
    const include_rejected = case_index % 3 == 0;

    for (0..@as(usize, @intCast(input.count))) |slot| {
        const offset_x = if (grid_positions) 0.01 * @as(f64, @floatFromInt(random.uintLessThan(u32, 40))) else randomPosition(random);
        var x = origin + offset_x;
        var z = origin + 0.01 * @as(f64, @floatFromInt(random.uintLessThan(u32, 40)));
        var box = [6]f64{ x - 0.45, origin - 0.45, z - 0.45, x + 0.45, origin + 0.45, z + 0.45 };

        const beside_edge = slot % 5 == 0;
        const touching_edge = slot % 7 == 0;
        const zero_width = slot % 11 == 0;
        const direction = if (slot % 2 == 0) -std.math.inf(f64) else std.math.inf(f64);
        if (beside_edge) box[kernel.BOUNDS_MIN_X] = std.math.nextAfter(f64, query.bounds[kernel.BOUNDS_MAX_X], direction);
        if (touching_edge) box[kernel.BOUNDS_MIN_X] = query.bounds[kernel.BOUNDS_MAX_X];
        if (zero_width) box[kernel.BOUNDS_MAX_X] = box[kernel.BOUNDS_MIN_X];
        if (special_bounds) box[random.uintLessThan(usize, 6)] = specialCoordinate(random);
        if (special_positions and slot % 3 == 0) x = specialCoordinate(random);
        if (near_push_threshold) {
            x = std.math.nextAfter(f64, origin + push_threshold, direction);
            z = origin;
        }

        var flag: f64 = 1;
        if (include_callbacks and slot % 9 == 0) {
            flag = -1;
        } else if (include_rejected and slot % 3 == 0) {
            flag = 0;
        }
        input.put(slot, box, x, z, flag);
    }
}

test "scalar and vector kernels agree on random inputs" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(20260925);
    const random = prng.random();

    const case_count = 4000;
    for (0..case_count) |case_index| {
        const special_origin = case_index % 4 == 0;
        const special_query_bounds = case_index % 29 == 0;
        const special_query_position = case_index % 31 == 0;
        const origin = if (special_origin) specialCoordinate(random) else randomPosition(random);

        var query = Query{
            .bounds = .{ -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 },
            .x = origin,
            .z = origin,
            .source_section = -1,
            .source_slot = -1,
            .retain_collisions = true,
        };
        for (&query.bounds) |*bound| bound.* += origin;
        if (special_query_bounds) query.bounds[random.uintLessThan(usize, 6)] = specialCoordinate(random);
        if (special_query_position) query.x = specialCoordinate(random);

        const section_count = 1 + case_index % 3;
        var inputs: [3]Input = undefined;
        var built: usize = 0;
        defer for (inputs[0..built]) |*input| input.deinit();

        for (0..section_count) |section| {
            inputs[section] = try Input.init(allocator, sectionSize(random, case_index, section), @intCast(random.uintLessThan(u32, 5)));
            built = section + 1;
            fillSection(random, &inputs[section], &query, origin, case_index);
        }

        if (case_index % 3 != 0) {
            query.source_section = @intCast(case_index % section_count);
            query.source_slot = @intCast(case_index % @max(1, inputs[@intCast(query.source_section)].count));
        }

        try check(allocator, inputs[0..section_count], query, case_index);
    }

    try check(allocator, &.{}, .{ .bounds = .{ 0, 0, 0, 1, 1, 1 }, .x = 0, .z = 0, .source_section = -1, .source_slot = -1, .retain_collisions = true }, case_count);
    std.debug.print("PASS {d} kernel comparisons\n", .{checks});
}

test "removed slots stay out of the results" {
    const allocator = std.testing.allocator;
    var input = try Input.init(allocator, 1033, 0);
    defer input.deinit();
    for (0..@as(usize, @intCast(input.count))) |slot| {
        const x = 0.5 + @as(f64, @floatFromInt(slot % 8)) * 0.01;
        input.put(slot, .{ 0.1, 0.1, 0.1, 0.9, 0.9, 0.9 }, x, 0.5, 1);
    }
    var slot: usize = 1;
    while (slot < @as(usize, @intCast(input.count))) : (slot += 7) input.remove(slot);

    var query = Query{
        .bounds = .{ -1, -1, -1, 2, 2, 2 },
        .x = 0.5,
        .z = 0.5,
        .source_section = 0,
        .source_slot = 0,
        .retain_collisions = true,
    };
    var sections = [_]Section{input.section()};
    for ([_]bool{ false, true }) |retain| {
        query.retain_collisions = retain;
        const expected = try allocator.alloc(i64, @as(usize, @intCast(input.count)) * kernel.OUTPUT_FIELDS);
        defer allocator.free(expected);
        const observed = try allocator.alloc(i64, expected.len);
        defer allocator.free(observed);
        @memset(expected, sentinel);
        @memset(observed, sentinel);

        const expected_count = kernel.scalar(&sections, 1, input.count, expected.ptr, &query);
        const result = kernel.batch(&sections, 1, input.count, observed.ptr, &query);
        try std.testing.expectEqual(expected_count, result);
        try std.testing.expectEqualSlices(i64, expected, observed);
    }
}

// --- spatial index -----------------------------------------------------------

/// Mirrors SpatialIndex.java / PositionGroups.java closely enough to build a
/// bitmap the native side would accept.
const TestIndex = struct {
    allocator: std.mem.Allocator,
    buffer: []align(8) u8,
    cells: []u8,
    words_per_row: i32,
    cell_count: i32 = 32,
    cell_shift: i32 = 5,
    origins: [3]i64,
    positions: []Pos,

    const Pos = struct { x: f64 = 0, z: f64 = 0, flag: f64 = 0, live: bool = false };

    const unset_cell: u8 = 32;

    fn init(allocator: std.mem.Allocator, capacity: usize, origin: [3]i64) !TestIndex {
        const words = @divTrunc(capacity + 63, 64);
        const bytes_per_row = words * 8;
        const boundary_rows = 6 * 32;
        const rows = boundary_rows + 4;
        const total = 40 + rows * bytes_per_row;
        const buffer = try allocator.alignedAlloc(u8, .of(u64), total);
        @memset(buffer, 0);
        const cells = try allocator.alloc(u8, capacity * 6);
        @memset(cells, unset_cell);
        const positions = try allocator.alloc(Pos, capacity);
        @memset(positions, .{});

        const self = TestIndex{
            .allocator = allocator,
            .buffer = buffer,
            .cells = cells,
            .words_per_row = @intCast(words),
            .origins = origin,
            .positions = positions,
        };
        var built = self;
        built.index().origins = origin;
        built.index().word_count = @intCast(words);
        built.index().cell_count = 32;
        built.index().cell_shift = 5;
        built.index().reserved = 0;
        return built;
    }

    fn deinit(self: *TestIndex) void {
        self.allocator.free(self.buffer);
        self.allocator.free(self.cells);
        self.allocator.free(self.positions);
    }

    fn index(self: *TestIndex) *SpatialIndex {
        return @ptrCast(@alignCast(self.buffer.ptr));
    }

    fn row(self: *TestIndex, row_index: i32) [*]u64 {
        const base = self.buffer.ptr + 40 + @as(usize, @intCast(row_index)) * @as(usize, @intCast(self.words_per_row)) * 8;
        return @ptrCast(@alignCast(base));
    }

    fn setBit(self: *TestIndex, row_index: i32, slot: usize, set: bool) void {
        const words = self.row(row_index);
        const word = slot / 64;
        const bit: u6 = @intCast(slot % 64);
        if (set) words[word] |= @as(u64, 1) << bit else words[word] &= ~(@as(u64, 1) << bit);
    }

    fn updateCell(self: *TestIndex, slot: usize, field: usize, coordinate: i32) void {
        const axis = field % 3;
        const local = (@as(i64, coordinate) - self.origins[axis]) >> @intCast(self.cell_shift);
        const new_cell: u8 = @intCast(std.math.clamp(local, 0, @as(i64, self.cell_count) - 1));
        const offset = slot * 6 + field;
        const previous = self.cells[offset];
        if (previous == new_cell) return;
        self.cells[offset] = new_cell;

        const first = @min(previous, new_cell);
        const end = @max(previous, new_cell);
        var boundary: u8 = first;
        while (boundary < end) : (boundary += 1) {
            self.setBit(@as(i32, @intCast(field)) * self.cell_count + @as(i32, boundary), slot, new_cell < previous);
        }
    }

    fn updateState(self: *TestIndex, slot: usize, x: f64, z: f64, flag: f64) void {
        const finite = std.math.isFinite(x) and std.math.isFinite(z);
        const fallback = flag < 0 or (flag != 0 and !finite);
        const eligible = flag != 0 and !fallback;
        self.setBit(6 * 32 + 2, slot, eligible);
        self.setBit(6 * 32 + 3, slot, fallback);
        self.positions[slot] = .{ .x = x, .z = z, .flag = flag, .live = true };
    }

    fn updateBounds(self: *TestIndex, slot: usize, bounds: [6]f64) void {
        var finite = true;
        for (bounds) |bound| {
            if (!std.math.isFinite(bound)) finite = false;
        }
        for (0..6) |field| {
            const empty: i32 = if (field < 3) std.math.minInt(i32) else std.math.maxInt(i32);
            const value = if (finite) kernel.quantize(bounds[field]) else empty;
            self.updateCell(slot, field, value);
        }
        self.setBit(6 * 32 + 1, slot, !finite);
    }

    fn remove(self: *TestIndex, slot: usize) void {
        self.setBit(6 * 32 + 2, slot, false);
        self.setBit(6 * 32 + 3, slot, false);
        self.positions[slot].live = false;
    }
};

test "spatial index path matches the brute force scan" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(424242);
    const random = prng.random();

    for (0..60) |_| {
        const count: usize = 64 + random.uintLessThan(u32, 200);
        const stride = count + 1;
        var input = try Input.init(allocator, @intCast(count), 1);
        defer input.deinit();

        var index = try TestIndex.init(allocator, stride, .{ 0, 0, 0 });
        defer index.deinit();

        var query = Query{
            .bounds = .{ -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 },
            .x = 0,
            .z = 0,
            .source_section = -1,
            .source_slot = -1,
            .retain_collisions = true,
        };

        for (0..count) |slot| {
            const x = @as(f64, @floatFromInt(random.uintLessThan(u32, 200))) * 0.1 - 10;
            const z = @as(f64, @floatFromInt(random.uintLessThan(u32, 200))) * 0.1 - 10;
            const flag: f64 = switch (random.uintLessThan(u32, 3)) {
                0 => 0,
                1 => -1,
                else => 1,
            };
            const bounds = [6]f64{ x - 0.45, -0.45, z - 0.45, x + 0.45, 0.45, z + 0.45 };
            const effective_flag = if (random.uintLessThan(u32, 12) == 0) 0 else flag;
            input.put(slot, bounds, x, z, effective_flag);
            index.updateBounds(slot, bounds);
            index.updateState(slot, x, z, effective_flag);
        }
        // Removed slots keep infinite bounds, exactly like RealtimeSection.clearBox.
        for (0..count / 8) |_| {
            const slot = random.uintLessThan(usize, count);
            if (index.positions[slot].live) {
                input.remove(slot);
                index.remove(slot);
            }
        }

        query.bounds = .{ -1.5, -1.5, -1.5, 1.5, 1.5, 1.5 };
        query.source_slot = -1;

        const plain = input.section();
        var indexed = input.section();
        indexed.spatial = index.index();
        const coincident = try allocator.alloc(u64, @intCast(index.words_per_row));
        defer allocator.free(coincident);
        @memset(coincident, 0);
        indexed.coincident = coincident.ptr;

        for ([_]bool{ true, false }) |retain| {
            query.retain_collisions = retain;
            var sections = [_]Section{plain};
            var indexed_sections = [_]Section{indexed};

            const expected = try allocator.alloc(i64, count * kernel.OUTPUT_FIELDS);
            defer allocator.free(expected);
            const observed = try allocator.alloc(i64, expected.len);
            defer allocator.free(observed);
            @memset(expected, sentinel);
            @memset(observed, sentinel);

            const expected_count = kernel.scalar(&sections, 1, @intCast(count), expected.ptr, &query);
            const result = kernel.batch(&indexed_sections, 1, @intCast(count), observed.ptr, &query);
            try std.testing.expectEqual(expected_count, result);
            // A fallback result may have partially written the buffer on both
            // sides, so only compare when the batch completed.
            if (result >= 0) try std.testing.expectEqualSlices(i64, expected, observed);
        }
    }
}
