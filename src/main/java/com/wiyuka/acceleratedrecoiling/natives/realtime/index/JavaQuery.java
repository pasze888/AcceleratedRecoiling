package com.wiyuka.acceleratedrecoiling.natives.realtime.index;

import java.util.List;

/**
 * Pure-Java counterpart of {@code ar_queryBatch}. Mirrors native/realtime/kernel.zig
 * one-to-one: the same bitmap intersection, the same exact f64 overlap test, the same
 * -1 "caller must fall back to vanilla" contract.
 */
public final class JavaQuery {
    private static final int COLLISIONS = 0;
    private static final int PUSHES = 1;

    /** Native computes {@code @floatCast(0.01)}: the f32 rounding is load-bearing. */
    private static final double PUSH_THRESHOLD = (double) 0.01F;

    private static final int CELL_SHIFT = SpatialIndex.CELL_SHIFT;
    private static final int CELL_COUNT = SpatialIndex.CELL_COUNT;
    private static final int CELL_MASK = SpatialIndex.CELL_COUNT - 1;

    private JavaQuery() {
    }

    /**
     * @return {@code ((long) collisions << 32) | pushes}, or -1 when the caller has to
     *         take the vanilla path for this tick.
     */
    public static long queryBatch(List<RealtimeSection.View> sections,
                                  int sourceSection, int sourceSlot,
                                  double sourceX, double sourceZ,
                                  double minX, double minY, double minZ,
                                  double maxX, double maxY, double maxZ,
                                  boolean retain, int entryCount, long[] output) {
        if (!Double.isFinite(sourceX) || !Double.isFinite(sourceZ)) {
            return -1;
        }

        double[] bounds = { minX, minY, minZ, maxX, maxY, maxZ };
        boolean boundsFinite = true;
        for (double bound : bounds) {
            if (!Double.isFinite(bound)) {
                boundsFinite = false;
                break;
            }
        }

        int[] quantized = boundsFinite ? quantizeBox(bounds) : null;
        int[] counters = { 0, 0 };

        for (int sectionIndex = 0; sectionIndex < sections.size(); sectionIndex++) {
            RealtimeSection.View view = sections.get(sectionIndex);
            SpatialIndex spatial = view.spatial();
            if (boundsFinite && spatial != null) {
                if (!indexedSection(view, spatial, sectionIndex, sourceSection, sourceSlot,
                        sourceX, sourceZ, bounds, quantized, retain, entryCount, output, counters)) {
                    return -1;
                }
                continue;
            }

            double[] data = view.bounds();
            int stride = view.stride;
            int count = view.count();
            for (int slot = 0; slot < count; slot++) {
                if (sectionIndex == sourceSection && slot == sourceSlot) {
                    continue;
                }
                if (!scalarCandidate(data, stride, sectionIndex, slot, sourceX, sourceZ, bounds,
                        retain, entryCount, output, counters)) {
                    return -1;
                }
            }
        }

        return ((long) counters[COLLISIONS] << 32) | (counters[PUSHES] & 0xFFFF_FFFFL);
    }

    private static boolean scalarCandidate(double[] data, int stride, int sectionIndex, int slot,
                                           double sourceX, double sourceZ, double[] bounds,
                                           boolean retain, int entryCount, long[] output,
                                           int[] counters) {
        if (!intersects(data, stride, slot, bounds)) {
            return true;
        }

        double flag = data[8 * stride + slot];
        if (flag < 0) {
            return false;
        }
        if (flag == 0) {
            return true;
        }

        double x = data[6 * stride + slot];
        double z = data[7 * stride + slot];
        if (!Double.isFinite(x) || !Double.isFinite(z)) {
            return false;
        }

        long hit = hitId(sectionIndex, slot);
        if (retain) {
            output[counters[COLLISIONS]] = hit;
        }
        counters[COLLISIONS]++;

        if (!(Math.abs(sourceX - x) < PUSH_THRESHOLD && Math.abs(sourceZ - z) < PUSH_THRESHOLD)) {
            output[entryCount + counters[PUSHES]] = hit;
            counters[PUSHES]++;
        }
        return true;
    }

    private static boolean indexedSection(RealtimeSection.View view, SpatialIndex spatial,
                                          int sectionIndex, int sourceSection, int sourceSlot,
                                          double sourceX, double sourceZ, double[] bounds,
                                          int[] quantized, boolean retain, int entryCount,
                                          long[] output, int[] counters) {
        long[] rows = spatial.rows();
        int wordsPerRow = spatial.wordsPerRow();
        long[] origins = spatial.origins();
        long[] coincident = view.coincidentBitmap(sourceX, sourceZ);
        double[] data = view.bounds();
        int stride = view.stride;
        int count = view.count();

        int minCellX = cellIndex(quantized[0], origins[0]);
        int minCellY = cellIndex(quantized[1], origins[1]);
        int minCellZ = cellIndex(quantized[2], origins[2]);
        int maxCellX = cellIndex(quantized[3], origins[0]);
        int maxCellY = cellIndex(quantized[4], origins[1]);
        int maxCellZ = cellIndex(quantized[5], origins[2]);

        int minXRow = prefixRow(0, maxCellX);
        int maxXRow = prefixRow(3, minCellX - 1);
        int minYRow = prefixRow(1, maxCellY);
        int maxYRow = prefixRow(4, minCellY - 1);
        int minZRow = prefixRow(2, maxCellZ);
        int maxZRow = prefixRow(5, minCellZ - 1);

        int minXBase = minXRow * wordsPerRow;
        int maxXBase = maxXRow * wordsPerRow;
        int minYBase = minYRow * wordsPerRow;
        int maxYBase = maxYRow * wordsPerRow;
        int minZBase = minZRow * wordsPerRow;
        int maxZBase = maxZRow * wordsPerRow;
        int eligibleBase = SpatialIndex.ELIGIBLE_ROW * wordsPerRow;
        int fallbackBase = SpatialIndex.FALLBACK_ROW * wordsPerRow;

        int words = (count + Long.SIZE - 1) / Long.SIZE;
        for (int word = 0; word < words; word++) {
            long candidateMask = rows[minXBase + word] & ~rows[maxXBase + word]
                    & rows[minYBase + word] & ~rows[maxYBase + word]
                    & rows[minZBase + word] & ~rows[maxZBase + word];

            if (sectionIndex == sourceSection && sourceSlot >= 0 && (sourceSlot >>> 6) == word) {
                candidateMask &= ~(1L << sourceSlot);
            }

            candidateMask &= rows[eligibleBase + word] | rows[fallbackBase + word];
            if (candidateMask == 0) {
                continue;
            }

            long collisionMask = 0;
            for (long pending = candidateMask; pending != 0; pending &= pending - 1) {
                int bit = Long.numberOfTrailingZeros(pending);
                int slot = (word << 6) + bit;
                if (intersects(data, stride, slot, bounds)) {
                    collisionMask |= 1L << bit;
                }
            }

            if ((collisionMask & rows[fallbackBase + word]) != 0) {
                return false;
            }

            if (retain) {
                for (long remaining = collisionMask; remaining != 0; remaining &= remaining - 1) {
                    int bit = Long.numberOfTrailingZeros(remaining);
                    output[counters[COLLISIONS]++] = hitId(sectionIndex, (word << 6) + bit);
                }
            } else {
                counters[COLLISIONS] += Long.bitCount(collisionMask);
            }

            long pushMask = collisionMask & ~(coincident == null ? 0L : coincident[word]);
            for (long pending = pushMask; pending != 0; pending &= pending - 1) {
                int bit = Long.numberOfTrailingZeros(pending);
                int slot = (word << 6) + bit;
                double dx = sourceX - data[6 * stride + slot];
                double dz = sourceZ - data[7 * stride + slot];
                if (Math.abs(dx) < PUSH_THRESHOLD && Math.abs(dz) < PUSH_THRESHOLD) {
                    continue;
                }
                output[entryCount + counters[PUSHES]++] = hitId(sectionIndex, slot);
            }
        }

        return true;
    }

    private static int prefixRow(int boundsField, int lastCell) {
        return lastCell < 0 ? SpatialIndex.EMPTY_ROW : boundsField * CELL_COUNT + lastCell;
    }

    private static int cellIndex(int coordinate, long scaledOrigin) {
        long local = (coordinate - scaledOrigin) >> CELL_SHIFT;
        if (local < 0) {
            return 0;
        }
        return local > CELL_MASK ? CELL_MASK : (int) local;
    }

    private static long hitId(int sectionIndex, int slot) {
        return ((long) sectionIndex << 32) | (slot & 0xFFFF_FFFFL);
    }

    private static boolean intersects(double[] data, int stride, int slot, double[] bounds) {
        return data[0 * stride + slot] < bounds[3]
                && data[3 * stride + slot] > bounds[0]
                && data[1 * stride + slot] < bounds[4]
                && data[4 * stride + slot] > bounds[1]
                && data[2 * stride + slot] < bounds[5]
                && data[5 * stride + slot] > bounds[2];
    }

    private static int[] quantizeBox(double[] bounds) {
        int[] result = new int[6];
        for (int field = 0; field < 6; field++) {
            result[field] = quantize(bounds[field]);
        }
        return result;
    }

    private static int quantize(double value) {
        double scaled = Math.floor(value * (double) SpatialIndex.SCALE);
        if (scaled <= Integer.MIN_VALUE) {
            return Integer.MIN_VALUE;
        }
        if (scaled >= Integer.MAX_VALUE) {
            return Integer.MAX_VALUE;
        }
        return (int) scaled;
    }
}
