package com.wiyuka.acceleratedrecoiling.natives.realtime.movement;

import net.minecraft.core.BlockPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.AirBlock;
import net.minecraft.world.level.block.BarrierBlock;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.phys.shapes.Shapes;

/**
 * Per-section collision classification, built one 16-block row at a time.
 *
 * <p>A {@code LevelChunkSection} holds 4096 blocks but a collision query only ever
 * touches the rows its box spans, so decoding every row up front is wasted work:
 * a typical entity box covers one or two rows. Rows are decoded on first use and
 * kept; {@code markDirty} drops only the rows that actually changed.
 *
 * <p>Decode-on-demand is adapted from Entity Collision Optimizer (MIT, © 2026
 * water2004), {@code CollisionRows} and {@code PalettedContainerMixin}.
 */
public final class SectionBlockIndex {
    /** Rows are indexed {@code z * 16 + y}, matching the block layout. */
    private static final int ROW_COUNT = 256;

    private final int[] fullRows = new int[ROW_COUNT];
    private final int[] specialRows = new int[ROW_COUNT];
    private final int[] largeRows = new int[ROW_COUNT];
    private final int[] pistonRows = new int[ROW_COUNT];
    private final long[] decoded = new long[ROW_COUNT / Long.SIZE];

    private SectionBlockIndex() {
    }

    static SectionBlockIndex get(LevelChunkSection section, Level level, int baseX, int baseY, int baseZ) {
        var storage = (VersionedBlockSection) section;
        var index = storage.ar$blockIndex();
        if (index == null) {
            index = new SectionBlockIndex();
            index.section = section;
            storage.ar$blockIndex(index);
        }
        index.level = level;
        index.baseX = baseX;
        index.baseY = baseY;
        index.baseZ = baseZ;
        return index;
    }

    /** {@code read} and {@code recalcBlockCounts} replace the palette wholesale. */
    public void invalidateAll() {
        java.util.Arrays.fill(decoded, 0L);
    }

    public void markDirty(int x, int y, int z) {
        int row = (z << 4) | y;
        decoded[row >>> 6] &= ~(1L << (row & 63));
    }

    private LevelChunkSection section;
    private Level level;
    private int baseX;
    private int baseY;
    private int baseZ;

    private boolean isDecoded(int row) {
        return (decoded[row >>> 6] & (1L << (row & 63))) != 0;
    }

    private void decodeRow(int row) {
        decoded[row >>> 6] |= 1L << (row & 63);
        fullRows[row] = 0;
        specialRows[row] = 0;
        largeRows[row] = 0;
        pistonRows[row] = 0;

        int y = row & 15;
        int z = row >> 4;
        var position = new BlockPos.MutableBlockPos();

        for (int x = 0; x < 16; x++) {
            BlockState state = section.getBlockState(x, y, z);
            if (state.isAir()) {
                continue;
            }

            int bit = 1 << x;
            if (state.hasLargeCollisionShape()) {
                largeRows[row] |= bit;
            }
            if (state.is(Blocks.MOVING_PISTON)) {
                pistonRows[row] |= bit;
            }

            var block = state.getBlock();
            var type = block.getClass();
            boolean supported = type == Block.class || type == AirBlock.class
                    || type == BarrierBlock.class;

            if (!supported || block.hasDynamicShape() || state.hasOffsetFunction()) {
                specialRows[row] |= bit;
                continue;
            }

            position.set(baseX + x, baseY + y, baseZ + z);
            var shape = state.getCollisionShape(level, position);
            if (shape == Shapes.block()) {
                fullRows[row] |= bit;
            } else if (!shape.isEmpty()) {
                specialRows[row] |= bit;
            }
        }
    }

    int row(int y, int z, int interiorMask, int edgeMask, int borderAxes) {
        int row = (z << 4) | y;
        if (!isDecoded(row)) {
            decodeRow(row);
        }

        int candidates = switch (borderAxes) {
            case 0 -> interiorMask | (edgeMask & largeRows[row]);
            case 1 -> (interiorMask & largeRows[row]) | (edgeMask & pistonRows[row]);
            default -> interiorMask & pistonRows[row];
        };

        if ((specialRows[row] & candidates) != 0) {
            return -1;
        }
        return fullRows[row] & candidates;
    }
}
