const std = @import("std");

/// Bitmap layout shared with SpatialIndex.java: a 40-byte header followed by
/// rows of u64 words. Field names match the C++ original.
pub const AXIS_COUNT = 3;
pub const BOUNDS_FIELD_COUNT = AXIS_COUNT * 2;
pub const CELL_COUNT = 32;

/// Row indices, shared with SpatialIndex.java. `needs_exact_bounds` and
/// `empty` keep their slot (Java still writes them) but no longer have a
/// reader in the kernel.
pub const Kind = enum(i32) { empty = 0, needs_exact_bounds = 1, eligible = 2, fallback = 3 };

pub const SpatialIndex = extern struct {
    origins: [AXIS_COUNT]i64,
    word_count: i32,
    cell_count: i32,
    cell_shift: i32,
    reserved: i32,

    comptime {
        std.debug.assert(@sizeOf(SpatialIndex) == 40);
    }

    inline fn bitmapData(self: *const SpatialIndex) [*]const u64 {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(SpatialIndex));
    }

    pub inline fn entityBitmap(self: *const SpatialIndex, kind: Kind) [*]const u64 {
        const boundary_rows = BOUNDS_FIELD_COUNT * self.cell_count;
        const row = boundary_rows + @intFromEnum(kind);
        return self.bitmapData() + @as(usize, @intCast(row)) * @as(usize, @intCast(self.word_count));
    }

    inline fn boundaryPrefix(self: *const SpatialIndex, bounds_field: i32, last_cell: i32) [*]const u64 {
        if (last_cell < 0) return self.entityBitmap(.empty);
        const row = bounds_field * self.cell_count + last_cell;
        return self.bitmapData() + @as(usize, @intCast(row)) * @as(usize, @intCast(self.word_count));
    }

    pub inline fn cellIndex(self: *const SpatialIndex, coordinate: i32, axis: usize) i32 {
        const local = (@as(i64, coordinate) - self.origins[axis]) >> @intCast(self.cell_shift);
        return @intCast(std.math.clamp(local, 0, @as(i64, self.cell_count) - 1));
    }
};

pub const SpatialQuery = struct {
    candidate_min: [AXIS_COUNT][*]const u64,
    candidate_max: [AXIS_COUNT][*]const u64,

    pub fn init(index: *const SpatialIndex, bounds: *const [BOUNDS_FIELD_COUNT]i32) SpatialQuery {
        var self: SpatialQuery = undefined;
        for (0..AXIS_COUNT) |axis| {
            const min_field: i32 = @intCast(axis);
            const max_field: i32 = @intCast(axis + AXIS_COUNT);
            const min_cell = index.cellIndex(bounds[@intCast(min_field)], axis);
            const max_cell = index.cellIndex(bounds[@intCast(max_field)], axis);

            self.candidate_min[axis] = index.boundaryPrefix(min_field, max_cell);
            self.candidate_max[axis] = index.boundaryPrefix(max_field, min_cell - 1);
        }

        return self;
    }

    /// Candidates only. The Java side also maintains a "confirmed" row set
    /// (boxes strictly inside the query), but reading those seven extra
    /// bitmaps cost more than the f64 overlap test it skipped, so the kernel
    /// no longer asks for them. The rows still exist in the bitmap layout.
    pub inline fn candidates(self: *const SpatialQuery, word: usize) u64 {
        return self.candidate_min[0][word] & ~self.candidate_max[0][word]
            & self.candidate_min[1][word] & ~self.candidate_max[1][word]
            & self.candidate_min[2][word] & ~self.candidate_max[2][word];
    }
};

test "header layout matches the Java descriptor" {
    var bytes: [40]u8 align(8) = undefined;
    @memset(&bytes, 0);
    const index: *SpatialIndex = @ptrCast(&bytes);
    index.origins = .{ 1, 2, 3 };
    index.word_count = 4;
    index.cell_count = CELL_COUNT;
    index.cell_shift = 5;
    try std.testing.expectEqual(@as(i64, 1), std.mem.readInt(i64, bytes[0..8], .little));
    try std.testing.expectEqual(@as(i64, 3), std.mem.readInt(i64, bytes[16..24], .little));
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, bytes[24..28], .little));
    try std.testing.expectEqual(@as(i32, CELL_COUNT), std.mem.readInt(i32, bytes[28..32], .little));
    try std.testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, bytes[32..36], .little));
}
