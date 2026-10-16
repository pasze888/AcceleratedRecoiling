package com.wiyuka.acceleratedrecoiling.natives.realtime.compat;

import com.wiyuka.acceleratedrecoiling.natives.realtime.index.IndexedEntity;
import java.util.concurrent.atomic.AtomicLong;
import net.minecraft.tags.BlockTags;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.TrapDoorBlock;
import net.minecraft.world.level.block.state.BlockState;

public final class BatchedRules {
    public static final int VANILLA_CALLBACKS = -1;
    public static final int REJECTED = 0;
    public static final int PUSHABLE = 1;

    private BatchedRules() {
    }

    private static final AtomicLong POLICY = new AtomicLong();

    public static long epoch() {
        return POLICY.get();
    }

    public static void invalidatePolicy() {
        POLICY.incrementAndGet();
    }

    private static boolean vanillaPackage(Class<?> anchor, Class<?> type) {
        String vanilla = anchor.getPackageName();
        String name = type.getPackageName();
        return name.equals(vanilla) || name.startsWith(vanilla + ".");
    }

    public static boolean plain(Class<?> type) {
        return vanillaPackage(Entity.class, type) && LivingEntity.class.isAssignableFrom(type);
    }

    public static boolean soft(Class<?> type) {
        return vanillaPackage(Entity.class, type);
    }

    public static int classify(Entity entity) {
        return classify(entity, false);
    }

    public static int classify(Entity entity, boolean allowUncachedState) {
        if (!plain(entity.getClass())) {
            return VANILLA_CALLBACKS;
        }
        LivingEntity living = (LivingEntity) entity;
        if (!living.isAlive()) {
            return REJECTED;
        }
        if (entity.getTeam() != null || entity.isPassenger() || entity.isVehicle()) {
            return VANILLA_CALLBACKS;
        }

        BlockState state = ((IndexedEntity) entity).ar$cachedBlockState();
        if (state == null) {
            if (!allowUncachedState) {
                return VANILLA_CALLBACKS;
            }
            state = entity.level().getBlockState(entity.blockPosition());
        }
        if (state.getClass() != BlockState.class
                || !vanillaPackage(Block.class, state.getBlock().getClass())) {
            return VANILLA_CALLBACKS;
        }

        return state.is(BlockTags.CLIMBABLE) || state.getBlock() instanceof TrapDoorBlock
                ? VANILLA_CALLBACKS : PUSHABLE;
    }
}
