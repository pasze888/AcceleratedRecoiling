package com.wiyuka.acceleratedrecoiling.natives.realtime;

import net.minecraft.core.BlockPos;
import net.minecraft.util.Mth;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.BooleanOp;
import net.minecraft.world.phys.shapes.Shapes;
import net.minecraft.world.phys.shapes.VoxelShape;

/**
 * Allocation-free rewrite of vanilla's {@code Entity.isInWall} probe.
 *
 * <p>Vanilla walks {@code BlockPos.betweenClosedStream(eyeBb).anyMatch(...)}, which
 * builds a stream, a spliterator and an {@code AbstractIterator} per entity per
 * tick, and calls {@code Shapes.create(eyeBb)} again for every candidate block.
 * The eye box is {@code width * 0.8} wide and {@code 1.0E-6} tall, so
 * {@code floor(minY) == floor(maxY)} and the candidate set is a single y layer of
 * one or two blocks; the stream machinery costs more than the scan.
 *
 * <p>The predicates themselves are unchanged and stay in vanilla's order: air,
 * then {@code isSuffocating}, then {@code Shapes.joinIsNotEmpty}. Only the
 * iteration and the eye shape are hoisted.
 *
 * <p>A {@code bounds().intersects()} pre-test before {@code joinIsNotEmpty} was
 * measured and reverted: on the packed bench every entity's eye box overlaps the
 * block it stands in, so the test never fired, and it made {@code isInWall}
 * 1.23 ms -> 1.55 ms per tick. The merger cost there is necessary, not waste.
 */
public final class EyeWall {
    private EyeWall() {
    }

    /**
     * The block range vanilla iterates, as {@code {minX, minY, minZ, maxX, maxY, maxZ}}.
     * Mirrors {@code BlockPos.betweenClosedStream(AABB)} exactly, floors included.
     */
    public static int[] scanBounds(AABB eyeBb) {
        return new int[] {
                Mth.floor(eyeBb.minX), Mth.floor(eyeBb.minY), Mth.floor(eyeBb.minZ),
                Mth.floor(eyeBb.maxX), Mth.floor(eyeBb.maxY), Mth.floor(eyeBb.maxZ)
        };
    }

    /** Same answer as vanilla's {@code isInWall} body, with the eye shape built once. */
    public static boolean inWall(Level level, AABB eyeBb) {
        int[] bounds = scanBounds(eyeBb);
        int minX = bounds[0], minY = bounds[1], minZ = bounds[2];
        int maxX = bounds[3], maxY = bounds[4], maxZ = bounds[5];

        VoxelShape eyeShape = Shapes.create(eyeBb);
        var pos = new BlockPos.MutableBlockPos();

        for (int y = minY; y <= maxY; y++) {
            for (int z = minZ; z <= maxZ; z++) {
                for (int x = minX; x <= maxX; x++) {
                    pos.set(x, y, z);
                    BlockState state = level.getBlockState(pos);
                    if (state.isAir()) {
                        continue;
                    }
                    if (!state.isSuffocating(level, pos)) {
                        continue;
                    }
                    if (Shapes.joinIsNotEmpty(state.getCollisionShape(level, pos).move(pos), eyeShape, BooleanOp.AND)) {
                        return true;
                    }
                }
            }
        }

        return false;
    }
}
