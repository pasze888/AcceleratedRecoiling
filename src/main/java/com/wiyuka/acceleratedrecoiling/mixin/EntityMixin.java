package com.wiyuka.acceleratedrecoiling.mixin;

import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import com.wiyuka.acceleratedrecoiling.natives.realtime.EyeWall;
import com.wiyuka.acceleratedrecoiling.natives.realtime.RealtimeNative;
import com.wiyuka.acceleratedrecoiling.natives.realtime.index.IndexedEntity;
import com.wiyuka.acceleratedrecoiling.natives.realtime.PushableMemoryEntity;
import com.wiyuka.acceleratedrecoiling.natives.realtime.index.RealtimeSection;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.EntityDimensions;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.AABB;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Entity.class)
public abstract class EntityMixin implements IndexedEntity {
    @Unique
    private RealtimeSection ar$section;

    @Unique
    private int ar$sectionSlot;

    @Shadow
    private BlockState inBlockState;

    /** Vanilla isInWall reads this field directly; refreshDimensions keeps it current. */
    @Shadow
    private EntityDimensions dimensions;

    @Override
    public void ar$bindSection(RealtimeSection section, int slot) {
        ar$section = section;
        ar$sectionSlot = slot;
    }

    @Override
    public void ar$unbindSection(RealtimeSection section) {
        if (ar$section == section) {
            ar$section = null;
        }
    }

    @Override
    public void ar$collisionStateDirty() {
        if (ar$section != null) {
            ar$section.stateDirty(ar$sectionSlot);
        }
        // 使isPushable缓存失效
        if (this instanceof PushableMemoryEntity memo) {
            memo.ar$invalidatePushable();
        }
    }

    @Override
    public BlockState ar$cachedBlockState() {
        return inBlockState;
    }

    @Override
    public RealtimeSection ar$section() {
        return ar$section;
    }

    @Override
    public int ar$sectionSlot() {
        return ar$sectionSlot;
    }

    @Inject(method = "setBoundingBox", at = @At("RETURN"))
    private void ar$boxChanged(AABB box, CallbackInfo ci) {
        if (ar$section != null) {
            ar$section.update(ar$sectionSlot, box);
        }
    }

    /**
     * Replace vanilla's stream-based eye probe with an allocation-free scan. The
     * {@code noPhysics} guard stays in vanilla's shape: a false answer from it is
     * indistinguishable from "not in a wall", so only the true branch is taken
     * over here and the original runs untouched for every other entity.
     */
    @WrapMethod(method = "isInWall")
    private boolean ar$eyeWall(Operation<Boolean> original) {
        Entity self = (Entity) (Object) this;
        if (!RealtimeNative.isEnabled() || self.noPhysics) {
            return original.call();
        }

        float checkWidth = dimensions.width() * 0.8F;
        AABB eyeBb = AABB.ofSize(self.getEyePosition(), checkWidth, 1.0E-6, checkWidth);
        return EyeWall.inWall(self.level(), eyeBb);
    }
}
