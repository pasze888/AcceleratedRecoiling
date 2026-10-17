package com.wiyuka.acceleratedrecoiling.natives.realtime;

import com.wiyuka.acceleratedrecoiling.AcceleratedRecoiling;
import java.io.IOException;
import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Locale;

public final class RealtimeNative {
    private static final int NATIVE_ABI_VERSION = 11;
    private static final Linker LINKER = Linker.nativeLinker();

    private static boolean attempted;
    private static volatile boolean loaded;
    private static volatile boolean disabled;
    private static Kernel kernel = Kernel.SCALAR;
    private static int quantizationThreshold;
    private static SymbolLookup library;
    private static MethodHandle queryBatchHandle;

    private RealtimeNative() {
    }

    public static synchronized void initialize() {
        if (attempted) {
            return;
        }
        attempted = true;
        try {
            String name = System.mapLibraryName("AcceleratedRecoilingRealtime");
            String resource = platformPath() + name;
            Path file = Files.createTempFile("ar-realtime-", "-" + name);
            file.toFile().deleteOnExit();
            try (var in = RealtimeNative.class.getResourceAsStream(resource)) {
                if (in == null) {
                    throw new IllegalStateException("Native collision library missing: " + resource);
                }
                Files.copy(in, file, StandardCopyOption.REPLACE_EXISTING);
            }

            // Arena.global() keeps the library mapped for the process
            // lifetime; a collected lookup would unload the code the cached
            // downcall handle points at.
            library = SymbolLookup.libraryLookup(file, Arena.global());
            queryBatchHandle = LINKER.downcallHandle(
                    symbol("ar_queryBatch"),
                    FunctionDescriptor.of(ValueLayout.JAVA_LONG,
                            ValueLayout.ADDRESS, ValueLayout.JAVA_INT, ValueLayout.ADDRESS,
                            ValueLayout.JAVA_LONG, ValueLayout.JAVA_LONG,
                            ValueLayout.JAVA_INT, ValueLayout.JAVA_INT,
                            ValueLayout.JAVA_DOUBLE, ValueLayout.JAVA_DOUBLE,
                            ValueLayout.JAVA_DOUBLE, ValueLayout.JAVA_DOUBLE, ValueLayout.JAVA_DOUBLE,
                            ValueLayout.JAVA_DOUBLE, ValueLayout.JAVA_DOUBLE, ValueLayout.JAVA_DOUBLE,
                            ValueLayout.JAVA_BOOLEAN));

            if (version() != NATIVE_ABI_VERSION) {
                throw new IllegalStateException("Unsupported native collision ABI");
            }

            // Call the batch entry point once, with the same buffer kinds the
            // real path hands over. This is the only way to compare the
            // descriptor above against native/realtime/exports.zig at load;
            // without it a drift only surfaces mid-tick, where it takes the
            // server down instead of falling back to vanilla collisions.
            probeQueryBatch();

            Kernel requested = Kernel.fromName(System.getProperty("ar.realtime.kernel", Kernel.AUTO.configName));
            int selectedKernel = selectKernel(requested.nativeId);
            if (selectedKernel < 0) {
                throw new IllegalStateException("Requested kernel is unsupported by CPU/OS: " + requested.configName);
            }
            kernel = Kernel.fromNativeId(selectedKernel);
            quantizationThreshold = quantizationMinEntities();
            loaded = true;
            AcceleratedRecoiling.LOGGER.info("NATIVE_BATCHED initialized: {}", kernelName());
        } catch (IOException | RuntimeException | LinkageError e) {
            AcceleratedRecoiling.LOGGER.warn("Native collision initialization failed; using vanilla collisions", e);
        }
    }

    public static boolean isEnabled() {
        return loaded && !disabled;
    }

    /**
     * Runtime A/B switch: the native library stays loaded and initialized, so
     * every accelerated path can be flipped back on without a restart.
     */
    public static void setEnabled(boolean enabled) {
        disabled = !enabled;
        AcceleratedRecoiling.LOGGER.info("AcceleratedRecoiling {}: {}", enabled ? "enabled" : "disabled",
                enabled ? kernelName() : "vanilla collisions");
    }

    /**
     * Zero sections, so the kernel only checks its arguments and returns
     * without touching entity data. Throws when the descriptor and the export
     * disagree, which {@link #initialize()} turns into the vanilla fallback.
     */
    private static void probeQueryBatch() {
        ByteBuffer plan = ByteBuffer.allocateDirect(64);
        ByteBuffer output = ByteBuffer.allocateDirect(64);
        queryBatch(plan, 0, output, 0, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false);
    }

    private static String platformPath() {
        String osName = System.getProperty("os.name").toLowerCase(Locale.ROOT);
        String os;
        if (osName.startsWith("windows")) {
            os = "windows";
        } else if (osName.contains("mac")) {
            os = "macos";
        } else if (osName.contains("linux")) {
            os = "linux";
        } else {
            throw new UnsupportedOperationException("Unsupported native platform");
        }
        String arch = switch (System.getProperty("os.arch").toLowerCase(Locale.ROOT)) {
            case "amd64", "x86_64" -> "x64";
            case "aarch64", "arm64" -> "arm64";
            default -> throw new UnsupportedOperationException("Unsupported native platform");
        };
        return "/natives/" + os + "-" + arch + "/";
    }

    private static MemorySegment symbol(String name) {
        return library.find(name).orElseThrow(
                () -> new IllegalStateException("Missing native symbol: " + name));
    }

    private static int version() {
        MethodHandle handle = LINKER.downcallHandle(symbol("ar_version"), FunctionDescriptor.of(ValueLayout.JAVA_INT));
        return invokeInt(handle);
    }

    private static int selectKernel(int requested) {
        MethodHandle handle = LINKER.downcallHandle(symbol("ar_selectKernel"),
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.JAVA_INT));
        try {
            return (int) handle.invokeExact(requested);
        } catch (Throwable error) {
            throw new IllegalStateException("Native selectKernel failed", error);
        }
    }

    private static int quantizationMinEntities() {
        MethodHandle handle = LINKER.downcallHandle(symbol("ar_quantizationMinEntities"),
                FunctionDescriptor.of(ValueLayout.JAVA_INT));
        return invokeInt(handle);
    }

    private static int invokeInt(MethodHandle handle) {
        try {
            return (int) handle.invokeExact();
        } catch (Throwable error) {
            throw new IllegalStateException("Native call failed", error);
        }
    }

    /**
     * The quantized pre-filter is chosen per section inside the native kernel,
     * so every SIMD kernel needs the int32 planes reserved. The section view
     * calls this to size its buffer, so it must stay in lockstep with the
     * native threshold.
     */
    public static boolean quantizeSection(int size) {
        return kernel != Kernel.SCALAR && size >= quantizationThreshold;
    }

    public static boolean usesSimd() {
        return kernel != Kernel.SCALAR;
    }

    public static String kernelName() {
        return kernel.configName;
    }

    public static long address(ByteBuffer buffer) {
        return MemorySegment.ofBuffer(buffer).address();
    }

    static long queryBatch(ByteBuffer sectionDescriptors, int sectionCount, ByteBuffer output,
            int sourceSection, int sourceSlot, double sourceX, double sourceZ,
            double minX, double minY, double minZ, double maxX, double maxY, double maxZ,
            boolean retainCollisions) {
        MemorySegment plan = MemorySegment.ofBuffer(sectionDescriptors);
        MemorySegment out = MemorySegment.ofBuffer(output);
        try {
            return (long) queryBatchHandle.invokeExact(plan, sectionCount, out,
                    (long) sectionDescriptors.capacity(), (long) output.capacity(),
                    sourceSection, sourceSlot, sourceX, sourceZ,
                    minX, minY, minZ, maxX, maxY, maxZ, retainCollisions);
        } catch (Throwable error) {
            throw new IllegalStateException("Native batch call failed", error);
        }
    }

    private enum Kernel {
        SIMD(-2, "simd"),
        AUTO(-1, "auto"),
        SCALAR(0, "scalar"),
        V1(1, "v1"),
        V2(2, "v2"),
        V3(3, "v3"),
        V4(4, "v4");

        private final int nativeId;
        private final String configName;

        Kernel(int nativeId, String configName) {
            this.nativeId = nativeId;
            this.configName = configName;
        }

        static Kernel fromName(String name) {
            // Old configurations named one kernel per ISA *and* per quantized
            // variant. The quantized pre-filter is now automatic inside the
            // kernel, so both spellings resolve to the matching ISA level.
            String normalized = switch (name.toLowerCase(Locale.ROOT)) {
                case "sse2", "quantized-sse2" -> "v1";
                case "avx2", "quantized-avx2" -> "v3";
                case "avx512", "quantized-avx512" -> "v4";
                default -> name.toLowerCase(Locale.ROOT);
            };
            for (Kernel kernel : values()) {
                if (kernel.configName.equals(normalized)) {
                    return kernel;
                }
            }
            throw new IllegalArgumentException("Unknown realtime kernel: " + name);
        }

        static Kernel fromNativeId(int nativeId) {
            for (Kernel kernel : values()) {
                if (kernel.nativeId == nativeId) {
                    return kernel;
                }
            }
            throw new IllegalStateException("Unknown native kernel: " + nativeId);
        }
    }
}
