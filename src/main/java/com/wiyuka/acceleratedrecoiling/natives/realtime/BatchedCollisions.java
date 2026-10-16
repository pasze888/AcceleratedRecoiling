package com.wiyuka.acceleratedrecoiling.natives.realtime;

import com.wiyuka.acceleratedrecoiling.mixin.BatchedLevelAccess;
import com.wiyuka.acceleratedrecoiling.mixin.RealtimeGetterAccess;
import com.wiyuka.acceleratedrecoiling.natives.realtime.compat.BatchedRules;
import com.wiyuka.acceleratedrecoiling.natives.realtime.index.IndexedEntity;
import com.wiyuka.acceleratedrecoiling.natives.realtime.index.IndexedSection;
import com.wiyuka.acceleratedrecoiling.natives.realtime.index.RealtimeSection;
import com.wiyuka.acceleratedrecoiling.natives.realtime.movement.BlockCollisionCache;
import java.lang.ref.Reference;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayDeque;
import java.util.ArrayList;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.Continuation;
import net.minecraft.util.profiling.Profiler;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.entity.EntitySectionStorage;
import net.minecraft.world.level.entity.LevelEntityGetterAdapter;
import net.minecraft.world.phys.AABB;
import net.neoforged.neoforge.common.config.NeoForgeServerConfig;

public final class BatchedCollisions {
    private static final int SECTION_ADDRESS_OFFSET = 0;
    private static final int SECTION_COUNT_OFFSET = SECTION_ADDRESS_OFFSET + Long.BYTES;
    private static final int SECTION_STRIDE_OFFSET = SECTION_COUNT_OFFSET + Integer.BYTES;
    private static final int SECTION_SPATIAL_OFFSET = SECTION_STRIDE_OFFSET + Integer.BYTES;
    private static final int SECTION_COINCIDENT_OFFSET = SECTION_SPATIAL_OFFSET + Long.BYTES;
    private static final int SECTION_DESCRIPTOR_BYTES = SECTION_COINCIDENT_OFFSET + Long.BYTES;

    private static final int OUTPUT_BYTES_PER_ENTRY = OutputField.values().length * Long.BYTES;

    private enum OutputField {
        COLLISIONS,
        PUSH_TARGETS;

        int byteOffset(int entries) {
            return ordinal() * entries * Long.BYTES;
        }
    }

    private BatchedCollisions() {
    }

    private static final ThreadLocal<ArrayDeque<Frame>> FRAMES = ThreadLocal.withInitial(ArrayDeque::new);

    private static final class Frame {
        final ArrayList<RealtimeSection.View> sections = new ArrayList<>();

        ByteBuffer sectionDescriptors = buffer(256);
        ByteBuffer output = buffer(4096);

        int entryCount;
        int sourceSection;

        void ensureCapacity() {
            if (sectionDescriptors.capacity() < (long) sections.size() * SECTION_DESCRIPTOR_BYTES) {
                sectionDescriptors = buffer(Math.multiplyExact(sections.size(), SECTION_DESCRIPTOR_BYTES * 2));
            }

            if (output.capacity() < (long) entryCount * OUTPUT_BYTES_PER_ENTRY) {
                output = buffer(Math.multiplyExact(entryCount, OUTPUT_BYTES_PER_ENTRY * 2));
            }
        }
    }

    private static ByteBuffer buffer(int bytes) {
        return ByteBuffer.allocateDirect(bytes).order(ByteOrder.nativeOrder());
    }

    public static void clear() {
        FRAMES.remove();
        BlockCollisionCache.clear();
    }

    @SuppressWarnings("unchecked")
    public static boolean noEntityObstacles(Entity source, AABB area) {
        if (source.level().getClass() != ServerLevel.class
                || !BatchedRules.plain(source.getClass())) {
            return false;
        }
        ServerLevel level = (ServerLevel) source.level();

        if (!level.dragonParts().isEmpty()) return false;

        var getter = ((BatchedLevelAccess) level).ar$entities();

        if (getter.getClass() != LevelEntityGetterAdapter.class) return false;
        var access = (RealtimeGetterAccess<Entity>) getter;

        boolean[] empty = { true };
        access.ar$sectionStorage().forEachAccessibleNonEmptySection(area.inflate(1.0E-7), section -> {
            if (!((IndexedSection) section).ar$realtimeSection().softOnly(section)) {
                empty[0] = false;
                return Continuation.ABORT;
            }
            return Continuation.CONTINUE;
        });
        if (empty[0] && !(area.getSize() < 1.0E-7)) {
            Profiler.get().incrementCounter("getEntities");
        }
        return empty[0];
    }

    @SuppressWarnings("unchecked")
    public static boolean tryPush(LivingEntity source) {
        if (!canPush(source)) {
            return false;
        }

        ServerLevel level = (ServerLevel) source.level();
        if (!level.dragonParts().isEmpty()) {
            return false;
        }
        var getter = ((BatchedLevelAccess) level).ar$entities();
        if (getter.getClass() != LevelEntityGetterAdapter.class) return false;
        var access = (RealtimeGetterAccess<Entity>) getter;

        var storage = access.ar$sectionStorage();

        var frames = FRAMES.get();
        Frame frame = frames.pollFirst();
        if (frame == null) {
            frame = new Frame();
        }

        try {
            long epoch = BatchedRules.epoch();
            var bounds = source.getBoundingBox();
            if (!collectSections(frame, level, storage, bounds, epoch)) return false;

            prepareSectionDescriptors(frame, source);
            return queryAndPush(source, level, bounds, frame);
        } finally {
            Reference.reachabilityFence(frame.sections);
            for (var section : frame.sections) section.release();
            frame.sections.clear();
            frames.addFirst(frame);
        }
    }

    private static boolean canPush(LivingEntity source) {
        return source.level().getClass() == ServerLevel.class
                && !NeoForgeServerConfig.INSTANCE.fullBoundingBoxLadders.get()
                && BatchedRules.classify(source, true) == BatchedRules.PUSHABLE;
    }

    private static boolean collectSections(Frame frame,
                                           ServerLevel level,
                                           EntitySectionStorage<Entity> storage,
                                           AABB bounds,
                                           long epoch) {
        boolean[] supported = { true };
        frame.entryCount = 0;

        storage.forEachAccessibleNonEmptySection(bounds, section -> {
            var index = ((IndexedSection) section).ar$realtimeSection();
            var view = index.view(section);
            if (view == null || !level.isPositionEntityTicking(view.sectionPosition)) {
                supported[0] = false;
                return Continuation.ABORT;
            }

            index.prepareBatch(epoch);
            frame.sections.add(view.retain());
            frame.entryCount = Math.addExact(frame.entryCount, view.count());
            return Continuation.CONTINUE;
        });

        return supported[0];
    }

    private static void prepareSectionDescriptors(Frame frame, LivingEntity source) {
        frame.ensureCapacity();

        var owner = ((IndexedEntity) source).ar$section();
        var sourceView = owner == null ? null : owner.currentView();
        frame.sourceSection = -1;

        for (int sectionIndex = 0; sectionIndex < frame.sections.size(); sectionIndex++) {
            var section = frame.sections.get(sectionIndex);
            if (section == sourceView) {
                frame.sourceSection = sectionIndex;
            }

            int offset = sectionIndex * SECTION_DESCRIPTOR_BYTES;
            frame.sectionDescriptors.putLong(offset + SECTION_ADDRESS_OFFSET, section.address);
            frame.sectionDescriptors.putInt(offset + SECTION_COUNT_OFFSET, section.count());
            frame.sectionDescriptors.putInt(offset + SECTION_STRIDE_OFFSET, section.stride);
            frame.sectionDescriptors.putLong(offset + SECTION_SPATIAL_OFFSET, section.spatialAddress());
            frame.sectionDescriptors.putLong(offset + SECTION_COINCIDENT_OFFSET,
                    section.coincidentAddress(source.getX(), source.getZ()));
        }
    }

    private static boolean queryAndPush(LivingEntity source,
                                        ServerLevel level,
                                        AABB bounds,
                                        Frame frame) {
        IndexedEntity indexedSource = (IndexedEntity) source;
        int crammingLimit = level.getGameRules().get(GameRules.MAX_ENTITY_CRAMMING);
        long counts = RealtimeNative.queryBatch(frame.sectionDescriptors, frame.sections.size(), frame.output, frame.sourceSection,
                indexedSource.ar$sectionSlot(), source.getX(), source.getZ(),
                bounds.minX, bounds.minY, bounds.minZ, bounds.maxX, bounds.maxY, bounds.maxZ,
                crammingLimit > 0);
        if (counts == -1) {
            return false;
        }

        if (counts < 0) {
            throw new IllegalStateException("Invalid native batch result: " + counts);
        }

        int collisionCount = (int) (counts >>> Integer.SIZE);
        int pushCount = (int) counts;
        if (pushCount < 0 || pushCount > collisionCount || collisionCount > frame.entryCount) {
            throw new IllegalStateException("Invalid native batch counts");
        }

        Profiler.get().incrementCounter("getEntities");
        dispatchPushes(source, level, frame, collisionCount, pushCount, crammingLimit);

        return true;
    }

    private static void dispatchPushes(LivingEntity source,
                                      ServerLevel level,
                                      Frame frame,
                                      int collisionCount,
                                      int pushCount,
                                      int crammingLimit) {
        boolean crammingAttempted = false;
        if (collisionCount > 0 && crammingLimit > 0 && collisionCount > crammingLimit - 1
                && source.getRandom().nextInt(4) == 0) {
            source.hurtServer(level, source.damageSources().cramming(), 6.0F);
            crammingAttempted = true;
        }

        int count = crammingAttempted ? collisionCount : pushCount;
        OutputField hits = crammingAttempted ? OutputField.COLLISIONS : OutputField.PUSH_TARGETS;
        int offset = hits.byteOffset(frame.entryCount);
        for (int index = 0; index < count; index++) {
            Entity other = collisionTarget(frame, offset, index);
            source.doPush(other);
        }
    }

    private static Entity collisionTarget(Frame frame, int offset, int index) {
        long hit = frame.output.getLong(offset + index * Long.BYTES);
        int sectionIndex = (int) (hit >>> Integer.SIZE);
        int entitySlot = (int) hit;
        return frame.sections.get(sectionIndex).entities[entitySlot];
    }
}
