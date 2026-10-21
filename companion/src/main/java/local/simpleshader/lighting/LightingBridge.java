package local.simpleshader.lighting;

import java.lang.reflect.Array;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.Vec3;
import org.joml.Vector3f;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL20;

/** Client-thread updates and integration through OptiFine custom textures. */
public final class LightingBridge {
    private static GpuLighting gpu;
    private static SceneVolume scan;
    private static SceneVolume pending;
    private static ColourSources colourSources;
    private static final TerrainFogCache terrainFog = new TerrainFogCache();
    private static final WaterMediumCache waterMedium = new WaterMediumCache();
    private static final OreGlowMasks oreMasks = new OreGlowMasks();
    private static final BlockWatch watch = new BlockWatch();
    private static long scanOrigin = Long.MIN_VALUE;
    private static ClientLevel world;
    private static ShaderSettings settings;
    private static long nextSettings;
    private static long nextScan;
    private static int scanBudget;
    private static boolean urgentScan;
    private static boolean failed;
    private static boolean updating;
    private static GpuLighting boundGpu;
    private static long boundRevision = -1;
    private static long nextProgramCheck;
    private static boolean boundReady;
    private static ShaderSettings.CameraFrame boundCameraFrame;

    private LightingBridge() {}

    public static void beginFrame() {
        if (updating || failed || !ShaderSettings.selected()) {
            return;
        }
        Minecraft client = Minecraft.getInstance();
        if (client.level == null || client.gameRenderer == null) {
            return;
        }
        long now = System.nanoTime();
        if (settings == null || now >= nextSettings) {
            ShaderSettings value = ShaderSettings.read();
            nextSettings = now + 250_000_000L;
            if (!value.sameResources(settings)) {
                updating = true;
                try (GlState state = new GlState()) {
                    if (gpu != null) {
                        gpu.close();
                    }
                    gpu = value.enabled ? new GpuLighting(value) : null;
                    scan = pending = null;
                    colourSources = new ColourSources();
                } catch (RuntimeException error) {
                    fail(error);
                } finally {
                    updating = false;
                }
            }
            settings = value;
        }
        if (!settings.enabled || gpu == null || failed) {
            return;
        }
        if (world != client.level) {
            world = client.level;
            scan = pending = null;
            colourSources = new ColourSources();
            nextScan = 0;
        }
        Vec3 camera = client.gameRenderer.getMainCamera().position();
        long origin = BlockPos.asLong(SceneVolume.origin(camera.x, settings.size),
            SceneVolume.origin(camera.y, settings.size), SceneVolume.origin(camera.z, settings.size));
        Set<Long> edits = watch.poll(world, camera);
        if (!edits.isEmpty()) {
            // A placed or broken block must not wait for the periodic scan:
            // rescan the volume now so its shadows and hue follow this frame.
            for (long section : edits) {
                colourSources.requeue(section);
                gpu.invalidateHue(section);
                gpu.invalidateLights(section);
            }
            // At most 48^3 cells: the radiance volume is scanned at once.
            scan = new SceneVolume(world, camera, settings);
            scanBudget = settings.size * settings.size * settings.size;
            urgentScan = true;
            scanOrigin = origin;
            nextScan = now + (long)(settings.interval * 1_000_000_000L);
        }
        if (scan == null && (now >= nextScan || origin != scanOrigin)) {
            scan = new SceneVolume(world, camera, settings);
            scanBudget = 16384;
            urgentScan = false;
            scanOrigin = origin;
            nextScan = now + (long)(settings.interval * 1_000_000_000L);
        }
        if (scan != null && scan.advance(scanBudget, urgentScan ? Long.MAX_VALUE : now + 2_000_000L)) {
            pending = scan;
            scan = null;
        }
        updating = true;
        try (GlState state = new GlState()) {
            // Emitters feed both the hue volume and the shadowed point lights.
            List<ColourSources.Source> sources = colourSources.advance(world, camera,
                client.options.renderDistance().get());
            // Hue updates do not wait for shadow maps or multi-bounce GI.
            if (settings.coloured) {
                gpu.setHueSources(world, sources, camera);
            } else {
                gpu.clearHue();
            }
            if (pending != null) {
                double day = (world.getDayTime() % 24000L) / 24000.0 - 0.25;
                day -= Math.floor(day);
                double eased = 0.5 - Math.cos(day * Math.PI) * 0.5;
                float angle = (float)((day * 2.0 + eased) / 3.0 * Math.PI * 2.0);
                Vector3f sun = new Vector3f(-(float)Math.sin(angle), (float)Math.cos(angle), 0.0f);
                float rain = world.getRainLevel(1.0f);
                float overcast = rain * rain * (3.0f - 2.0f * rain);
                Vector3f color;
                if (sun.y >= 0.0f) {
                    float height = Math.max(sun.y, 0.03f);
                    color = new Vector3f((float)Math.exp(-0.075f / height),
                        (float)Math.exp(-0.12f / height), (float)Math.exp(-0.26f / height))
                        .mul(settings.sunStrength * (1.0f - 0.80f * overcast));
                } else {
                    sun.negate();
                    float phase = 0.08f + 0.92f * (0.5f + 0.5f * (float)Math.cos(
                        ((world.getDayTime() / 24000L) % 8) * Math.PI * 0.25));
                    color = new Vector3f(0.8f, 0.86f, 1.0f)
                        .mul(settings.moonStrength * phase * (1.0f - 0.65f * overcast));
                }
                // Nether and End have no sun or moon. Keep local emitters and
                // their bounce transport, without injecting a fictitious sun.
                if (!world.dimension().equals(Level.OVERWORLD)) {
                    sun.set(0.0f, 1.0f, 0.0f);
                    color.zero();
                }
                gpu.setScene(pending, sun, color, settings);
                pending = null;
            }
            gpu.setLights(world, sources, camera, settings);
            gpu.advance(settings, System.nanoTime() + 2_000_000L);
            terrainFog.advance(world, camera);
            gpu.setTerrainFog(terrainFog, camera);
            gpu.setWaterMedium(waterMedium.update(world, camera));
            oreMasks.advance(client);
            gpu.setOreMasks(oreMasks);
        } catch (RuntimeException error) {
            fail(error);
        } finally {
            updating = false;
        }
    }

    public static void bind() {
        if (updating || gpu == null) {
            return;
        }
        int program = GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM);
        if (program == 0) {
            return;
        }
        if (failed || settings == null || !settings.enabled || !ShaderSettings.selected()
            || Minecraft.getInstance().level == null) {
            GL20.glUniform1i(GL20.glGetUniformLocation(program, "companionReady"), 0);
            return;
        }
        try {
            gpu.bind(program, ShaderSettings.cameraFrame());
        } catch (RuntimeException error) {
            fail(error);
        }
    }

    /** Refresh uniforms on scene/GI publication or shader reload, rather than
     * switching every shader program on each scheduler tick. Texture providers
     * continue to supply the current ping-pong texture for every render pass.
     */
    public static void bindPrograms() {
        if (updating || gpu == null || !ShaderSettings.selected()) {
            return;
        }
        long now = System.nanoTime();
        long revision = gpu.bindingRevision();
        boolean ready = !failed && settings != null && settings.enabled
            && Minecraft.getInstance().level != null;
        try {
            ShaderSettings.CameraFrame frame = ShaderSettings.cameraFrame();
            boolean sameFrame = frame.equals(boundCameraFrame);
            if (boundGpu == gpu && boundRevision == revision && boundReady == ready
                && sameFrame && now < nextProgramCheck) {
                return;
            }
            Class<?> shaders = Class.forName("net.optifine.shaders.Shaders");
            boolean reloaded = installTextures(shaders);
            nextProgramCheck = now + 250_000_000L;
            if (!reloaded && boundGpu == gpu && boundRevision == revision && boundReady == ready && sameFrame) {
                return;
            }
            Object[] programs = (Object[]) shaders.getField("ProgramsAll").get(null);
            int previous = GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM);
            Set<Integer> seen = new HashSet<>();
            try {
                for (Object program : programs) {
                    int id = (Integer) program.getClass().getMethod("getId").invoke(program);
                    if (id == 0 || !seen.add(id)) {
                        continue;
                    }
                    GL20.glUseProgram(id);
                    if (failed || settings == null || !settings.enabled
                        || Minecraft.getInstance().level == null) {
                        GL20.glUniform1i(GL20.glGetUniformLocation(id, "companionReady"), 0);
                    } else {
                        gpu.bind(id, frame);
                    }
                }
            } finally {
                GL20.glUseProgram(previous);
            }
            boundGpu = gpu;
            boundRevision = revision;
            boundReady = ready;
            if (!sameFrame) {
                CompanionMod.LOGGER.info("SIMPLE_LIGHTING shader camera offset x={} z={}", frame.x(), frame.z());
            }
            boundCameraFrame = frame;
        } catch (ReflectiveOperationException | RuntimeException error) {
            fail(new IllegalStateException("OptiFine texture integration failed", error));
        }
    }

    /** Append dynamic texture providers after the pack's own custom textures. */
    private static boolean installTextures(Class<?> shaders) throws ReflectiveOperationException {
        Class<?> textureType = Class.forName("net.optifine.shaders.ICustomTexture");
        boolean changed = false;
        for (String name : new String[] {"customTexturesGbuffers", "customTexturesComposite", "customTexturesDeferred"}) {
            Field field = shaders.getDeclaredField(name);
            field.setAccessible(true);
            Object old = field.get(null);
            List<Object> retained = new ArrayList<>();
            boolean installed = false;
            if (old != null) {
                for (int index = 0; index < Array.getLength(old); index++) {
                    Object texture = Array.get(old, index);
                    if (Proxy.isProxyClass(texture.getClass())
                        && Proxy.getInvocationHandler(texture) instanceof TextureBinding) {
                        installed = true;
                    }
                    retained.add(texture);
                }
            }
            if (installed) {
                continue;
            }
            retained.add(Proxy.newProxyInstance(textureType.getClassLoader(), new Class<?>[] {textureType}, new TextureBinding(12)));
            retained.add(Proxy.newProxyInstance(textureType.getClassLoader(), new Class<?>[] {textureType}, new TextureBinding(14)));
            Object replacement = Array.newInstance(textureType, retained.size());
            for (int index = 0; index < retained.size(); index++) {
                Array.set(replacement, index, retained.get(index));
            }
            field.set(null, replacement);
            changed = true;
        }
        return changed;
    }

    /** Implements the installed loader interface while avoiding a binary dependency. */
    private static final class TextureBinding implements InvocationHandler {
        private final int unit;
        TextureBinding(int unit) { this.unit = unit; }
        @Override
        public Object invoke(Object proxy, java.lang.reflect.Method method, Object[] arguments) {
            return switch (method.getName()) {
                case "getTextureUnit" -> unit;
                case "getTextureId" -> gpu == null ? 0 : unit == 12 ? gpu.atlasTexture() : gpu.radianceTexture();
                case "getTarget" -> GL11.GL_TEXTURE_2D;
                case "deleteTexture" -> null;
                case "toString" -> "SimpleShader lighting texture " + unit;
                case "hashCode" -> System.identityHashCode(proxy);
                case "equals" -> proxy == arguments[0];
                default -> null;
            };
        }
    }

    static void fail(RuntimeException error) {
        failed = true;
        CompanionMod.LOGGER.error("SIMPLE_LIGHTING disabled after error", error);
    }
}
