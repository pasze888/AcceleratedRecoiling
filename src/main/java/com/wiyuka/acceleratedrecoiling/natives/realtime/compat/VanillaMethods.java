package com.wiyuka.acceleratedrecoiling.natives.realtime.compat;

import java.lang.reflect.Method;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.phys.Vec3;

/**
 * Answers "does this entity class actually run the vanilla body of method X?"
 * by comparing the method's declaring class against the expected owner.
 *
 * <p>Checking the package name (as {@code vanillaPackage} does) is not enough:
 * a mod entity living under {@code net.minecraft.*} can still override
 * {@code getTeam}, {@code canCollideWith} or {@code doPush} and add behaviour the
 * batch path would silently drop. {@link ClassValue} caches one answer per
 * class and the JDK owns the lifetime, so this costs nothing on the hot path.
 *
 * <p>Adapted from Entity Collision Optimizer (MIT, © 2026 water2004),
 * {@code org.edtp.entitycollisionoptimizer.collision.VanillaMethodDetector}.
 */
public final class VanillaMethods {
    private VanillaMethods() {
    }

    /** Entity.getTeam is the only scoreboard lookup vanilla caches; derived teams (TamableAnimal) are read live. */
    private static final ClassValue<Boolean> PLAIN_GET_TEAM = declaringClass("getTeam", Entity.class);

    private static final ClassValue<Boolean> PLAIN_CAN_COLLIDE_WITH =
            declaringClass("canCollideWith", Entity.class, Entity.class);

    private static final ClassValue<Boolean> PLAIN_CAN_BE_COLLIDED_WITH =
            declaringClass("canBeCollidedWith", Entity.class, Entity.class);
    // Vanilla declares canBeCollidedWith(Entity) with an unused parameter; boats and
    // shulkers override it to return true, which decides whether they are hard targets.

    /** Entity.push(Entity) computes the impulse; LivingEntity adds a sleeping guard the batch path applies live. */
    private static final ClassValue<Boolean> PLAIN_ENTITY_PUSH = new ClassValue<>() {
        @Override
        protected Boolean computeValue(Class<?> type) {
            Class<?> owner = declaredOwner(type, "push", Entity.class);
            return owner == Entity.class || owner == LivingEntity.class;
        }
    };

    /** Entity.push(double, double, double) is the impulse writer; overrides change what it does. */
    private static final ClassValue<Boolean> PLAIN_VECTOR_PUSH =
            new ClassValue<>() {
                @Override
                protected Boolean computeValue(Class<?> type) {
                    return declaredOwner(type, "push", double.class, double.class, double.class) == Entity.class;
                }
            };

    private static final ClassValue<Boolean> PLAIN_VELOCITY_GETTER =
            declaringClass("getDeltaMovement", Entity.class);

    private static final ClassValue<Boolean> PLAIN_VELOCITY_SETTER =
            declaringClass("setDeltaMovement", Entity.class, Vec3.class);

    /** doPush owns the per-target side effects (cramming damage, random draws, item frame kills). */
    private static final ClassValue<Boolean> PLAIN_DO_PUSH = new ClassValue<>() {
        @Override
        protected Boolean computeValue(Class<?> type) {
            Class<?> owner = declaredOwner(type, "doPush", Entity.class);
            return owner == LivingEntity.class;
        }
    };

    public static boolean usesVanillaGetTeam(Entity entity) {
        return PLAIN_GET_TEAM.get(entity.getClass());
    }

    public static boolean usesVanillaCanCollideWith(Class<?> type) {
        return PLAIN_CAN_COLLIDE_WITH.get(type);
    }

    public static boolean usesVanillaCanBeCollidedWith(Class<?> type) {
        return PLAIN_CAN_BE_COLLIDED_WITH.get(type);
    }

    public static boolean usesVanillaEntityPush(Class<?> type) {
        return PLAIN_ENTITY_PUSH.get(type);
    }

    public static boolean usesVanillaDoPush(Class<?> type) {
        return PLAIN_DO_PUSH.get(type);
    }

    /** A batch may write velocity only when every accessor on the pair is vanilla's own. */
    public static boolean allowsDeferredVelocityWrites(Class<?> type) {
        return PLAIN_VECTOR_PUSH.get(type)
                && PLAIN_VELOCITY_GETTER.get(type)
                && PLAIN_VELOCITY_SETTER.get(type);
    }

    /** True when {@code type} runs vanilla's collision behaviour for every method the batch path replaces. */
    public static boolean plainCollisionBehaviour(Class<?> type) {
        return usesVanillaCanCollideWith(type) && usesVanillaCanBeCollidedWith(type)
                && usesVanillaEntityPush(type) && usesVanillaDoPush(type)
                && allowsDeferredVelocityWrites(type);
    }

    private static ClassValue<Boolean> declaringClass(String method, Class<?> expectedOwner, Class<?>... parameters) {
        return new ClassValue<>() {
            @Override
            protected Boolean computeValue(Class<?> type) {
                return declaredOwner(type, method, parameters) == expectedOwner;
            }
        };
    }

    private static Class<?> declaredOwner(Class<?> type, String method, Class<?>... parameters) {
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            try {
                Method found = current.getDeclaredMethod(method, parameters);
                return found.getDeclaringClass();
            } catch (NoSuchMethodException ignored) {
                // Keep walking up; the method lives somewhere in the hierarchy.
            }
        }
        return null;
    }
}
