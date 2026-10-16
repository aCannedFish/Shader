package local.simpleshader.lighting;

import java.lang.reflect.Method;
import java.lang.reflect.Field;
import java.util.HashMap;
import java.util.Map;

/** Read the selected shader options without requiring an OptiFine compile dependency. */
final class ShaderSettings {
    record CameraFrame(int x, int z) {}

    private static Field cameraOffsetX;
    private static Field cameraOffsetZ;
    final int size;
    final int lightLimit;
    final int shadowResolution;
    final int shadowUpdates;
    final int bounces;
    final int propagationSteps;
    final int workPerFrame;
    final float radius;
    final float blockStrength;
    final float sunStrength;
    final float moonStrength;
    final float reflectance;
    final float interval;
    final boolean enabled;
    final boolean coloured;

    private ShaderSettings(Map<String, String> options) {
        size = integer(options, "GI_VOLUME_SIZE", 32, 16, 48);
        lightLimit = integer(options, "LOCAL_LIGHT_COUNT", 32, 8, 128);
        shadowResolution = integer(options, "LOCAL_SHADOW_RESOLUTION", 128, 32, 256);
        shadowUpdates = integer(options, "LOCAL_SHADOW_UPDATES", 2, 1, 16);
        bounces = integer(options, "GI_BOUNCES", 3, 0, 6);
        propagationSteps = integer(options, "GI_PROPAGATION_STEPS", 8, 2, 24);
        workPerFrame = integer(options, "GI_WORK_PER_FRAME", 4, 1, 16);
        blockStrength = number(options, "BLOCK_LIGHT_STRENGTH", 1.0f, 0.0f, 4.0f);
        sunStrength = number(options, "SUNLIGHT_STRENGTH", 1.0f, 0.0f, 4.0f);
        moonStrength = number(options, "MOONLIGHT_STRENGTH", 0.03f, 0.0f, 0.2f);
        radius = number(options, "LOCAL_LIGHT_RADIUS", 16.0f, 4.0f, 24.0f);
        reflectance = number(options, "GI_REFLECTANCE", 0.75f, 0.1f, 0.9f);
        interval = number(options, "LIGHTING_UPDATE_INTERVAL", 0.5f, 0.05f, 2.0f);
        enabled = integer(options, "ENABLE_COMPANION_LIGHTING", 1, 0, 1) == 1;
        coloured = integer(options, "ENABLE_COLOURED_LIGHTING", 1, 0, 1) == 1;
    }

    static ShaderSettings read() {
        Map<String, String> options = new HashMap<>();
        try {
            Class<?> shaders = Class.forName("net.optifine.shaders.Shaders");
            Object[] values = (Object[]) shaders.getMethod("getShaderPackOptions").invoke(null);
            if (values != null) {
                for (Object value : values) {
                    Method name = value.getClass().getMethod("getName");
                    Method setting = value.getClass().getMethod("getValue");
                    options.put((String) name.invoke(value), (String) setting.invoke(value));
                }
            }
        } catch (ReflectiveOperationException unavailable) {
            options.put("ENABLE_COMPANION_LIGHTING", "0");
        }
        return new ShaderSettings(options);
    }

    static boolean selected() {
        try {
            Class<?> shaders = Class.forName("net.optifine.shaders.Shaders");
            String name = (String) shaders.getField("currentShaderName").get(null);
            return name != null && name.startsWith("SimpleShader");
        } catch (ReflectiveOperationException unavailable) {
            return false;
        }
    }

    /** OptiFine rebases cameraPosition by whole thousands; GPU origins need the same frame. */
    static CameraFrame cameraFrame() {
        try {
            if (cameraOffsetX == null) {
                Class<?> shaders = Class.forName("net.optifine.shaders.Shaders");
                cameraOffsetX = shaders.getDeclaredField("cameraOffsetX");
                cameraOffsetZ = shaders.getDeclaredField("cameraOffsetZ");
                cameraOffsetX.setAccessible(true);
                cameraOffsetZ.setAccessible(true);
            }
            return new CameraFrame(cameraOffsetX.getInt(null), cameraOffsetZ.getInt(null));
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Cannot read the OptiFine camera coordinate frame", error);
        }
    }

    boolean sameResources(ShaderSettings other) {
        return other != null && size == other.size && lightLimit == other.lightLimit
            && shadowResolution == other.shadowResolution;
    }

    private static int integer(Map<String, String> options, String name, int fallback, int minimum, int maximum) {
        try {
            return Math.max(minimum, Math.min(maximum, Integer.parseInt(options.get(name))));
        } catch (NumberFormatException invalid) {
            return fallback;
        }
    }

    private static float number(Map<String, String> options, String name, float fallback, float minimum, float maximum) {
        try {
            return Math.max(minimum, Math.min(maximum, Float.parseFloat(options.get(name))));
        } catch (NullPointerException | NumberFormatException invalid) {
            return fallback;
        }
    }
}
