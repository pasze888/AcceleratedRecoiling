package com.wiyuka.acceleratedrecoiling.natives.realtime;

import com.wiyuka.acceleratedrecoiling.AcceleratedRecoiling;

/**
 * Pure-Java build: there is no native library any more. This class keeps the
 * small surface the rest of the mod switches on, so every call site reads the
 * same with or without a native kernel underneath.
 */
public final class RealtimeNative {
    private static volatile boolean disabled;

    private RealtimeNative() {
    }

    public static void initialize() {
        AcceleratedRecoiling.LOGGER.info("NATIVE_BATCHED initialized: {}", kernelName());
    }

    public static boolean isEnabled() {
        return !disabled;
    }

    /**
     * Runtime A/B switch, same contract the native build had.
     */
    public static void setEnabled(boolean enabled) {
        disabled = !enabled;
        AcceleratedRecoiling.LOGGER.info("AcceleratedRecoiling {}: {}", enabled ? "enabled" : "disabled",
                enabled ? kernelName() : "vanilla collisions");
    }

    /**
     * The int32 pre-filter only pays off for SIMD. A scalar JVM test costs more
     * than the f64 compare it replaces, so the Java kernel never asks for the
     * quantized planes.
     */
    public static boolean quantizeSection(int size) {
        return false;
    }

    public static boolean usesSimd() {
        return true;
    }

    public static String kernelName() {
        return "java";
    }
}
