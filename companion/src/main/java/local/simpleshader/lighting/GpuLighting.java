package local.simpleshader.lighting;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Map;
import java.util.List;
import java.util.PriorityQueue;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.SectionPos;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.Vec3;
import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL12;
import org.lwjgl.opengl.GL13;
import org.lwjgl.opengl.GL14;
import org.lwjgl.opengl.GL15;
import org.lwjgl.opengl.GL20;
import org.lwjgl.opengl.GL30;

/** Rasterize independent point-light maps and propagate diffuse radiance on the GPU. */
final class GpuLighting implements AutoCloseable {
    private static final int HEADER = 16;
    private static final int TILES_ACROSS = 24;
    /** Floats per light record: three atlas texels. */
    private static final int LIGHT_STRIDE = 12;
    /** Shadowed lights fade in after their first map and fade out before release. */
    private static final float FADE_SECONDS = 0.4f;
    /** Every mapped light re-gathers its occluders this often to catch distant edits. */
    private static final float REFRESH_SECONDS = 4.0f;
    private final ShaderSettings resources;
    private final int width;
    private final int height;
    private final int transmissionStart;
    private final int transmissionColumns;
    private final int transmissionWidth;
    private final int transmissionHeight;
    private final int hueStart;
    private final int poolStart;
    private final HueVolume hue = new HueVolume();
    private final float[] header;
    private final int atlas;
    private final int depth;
    private final int shadowFramebuffer;
    private final int voxelTexture;
    private final int absorptionTexture;
    private final int shadowProgram;
    private final int transmissionProgram;
    private final int injectProgram;
    private final int propagateProgram;
    private final int accumulateProgram;
    private final int packProgram;
    private final int meshArray;
    private final int meshBuffer;
    private final int glassArray;
    private final int glassBuffer;
    private final int lightArray;
    private final int lightBuffer;
    private final int lightGlassArray;
    private final int lightGlassBuffer;
    private final int quadArray;
    private final Field[] steps = new Field[2];
    private final Field[] sums = new Field[2];
    private final Field[] totals = new Field[2];
    private final Field previousBounce;
    private final int[] packed = new int[2];
    private final int packedFramebuffer;
    private final Map<Integer, Map<String, Integer>> locations = new HashMap<>();
    private final Matrix4f sunMatrix = new Matrix4f();
    private final Vector3f sunDirection = new Vector3f();
    private final Vector3f sunColor = new Vector3f();
    private SceneVolume scene;
    private boolean hueValid;
    private int hueX;
    private int hueY;
    private int hueZ;
    /** Each emitter keeps its atlas slot and maps while it stays selected. */
    private final PointLight[] slots;
    private final boolean[] mapped;
    private final boolean[] transmitted;
    private final boolean[] leaving;
    private final float[] fades;
    private final int[] meshHashes;
    /** Selected lights still waiting for a free slot, nearest first. */
    private final ArrayDeque<PointLight> waiting = new ArrayDeque<>();
    private List<ColourSources.Source> lightSources;
    private Vec3 lightCamera;
    private boolean lightColoured;
    private float lightRadius;
    private ClientLevel level;
    private long lastAdvance;
    private float refreshDue;
    private int refreshCursor;
    private final ArrayDeque<Integer> shadowQueue = new ArrayDeque<>();
    private final ArrayDeque<Integer> transmissionQueue = new ArrayDeque<>();
    private int slotCount;
    private final Vector3f publishedSunColor = new Vector3f();
    private ShaderSettings sceneSettings;
    private int vertices;
    private int glassVertices;
    private int bounce;
    private int iteration;
    private int currentStep;
    private int currentSum;
    private int currentTotal;
    private int currentPacked;
    private boolean calculating;
    private boolean giValid;
    private boolean sunRendered;
    private int giOriginX;
    private int giOriginY;
    private int giOriginZ;
    private long bindingRevision;
    private int loggedBounces = -1;
    private int loggedLights = -1;

    /** Three RGB bands store four first-order SH coefficients each. */
    private final class Field {
        final int framebuffer = GL30.glGenFramebuffers();
        final int[] textures = new int[3];
        Field() {
            GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, framebuffer);
            for (int band = 0; band < 3; band++) {
                textures[band] = texture(resources.size * 8, resources.size * ((resources.size + 7) / 8), GL30.GL_RGBA16F, false);
                GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_COLOR_ATTACHMENT0 + band,
                                            GL11.GL_TEXTURE_2D, textures[band], 0);
            }
            GL20.glDrawBuffers(new int[] {GL30.GL_COLOR_ATTACHMENT0, GL30.GL_COLOR_ATTACHMENT1, GL30.GL_COLOR_ATTACHMENT2});
            checkFramebuffer();
        }
        void clear() {
            target(this);
            GL11.glClearColor(0, 0, 0, 0);
            GL11.glClear(GL11.GL_COLOR_BUFFER_BIT);
        }
        void delete() {
            GL30.glDeleteFramebuffers(framebuffer);
            for (int texture : textures) { GL11.glDeleteTextures(texture); }
        }
    }

    GpuLighting(ShaderSettings settings) {
        resources = settings;
        transmissionStart = HEADER + ((settings.lightLimit * 6 + 1 + TILES_ACROSS - 1) / TILES_ACROSS) * settings.shadowResolution;
        transmissionWidth = (settings.size + 2) * 8;
        transmissionHeight = (settings.size + 2) * ((settings.size + 7) / 8);
        int cacheColumns = (int) Math.ceil(Math.sqrt((settings.lightLimit + 1.0) * transmissionHeight / transmissionWidth));
        width = Math.max(TILES_ACROSS * settings.shadowResolution, cacheColumns * transmissionWidth);
        transmissionColumns = width / transmissionWidth;
        hueStart = transmissionStart + ((settings.lightLimit + 1 + transmissionColumns - 1) / transmissionColumns) * transmissionHeight;
        // Brick indirection rows, then the pool of 64x8-texel hue bricks.
        poolStart = hueStart + (HueVolume.BRICKS + width - 1) / width;
        int perRow = width / (HueVolume.BRICK * HueVolume.BRICK);
        height = poolStart + (HueVolume.POOL + perRow - 1) / perRow * HueVolume.BRICK;
        header = new float[settings.lightLimit * LIGHT_STRIDE + 16];
        slots = new PointLight[settings.lightLimit];
        mapped = new boolean[settings.lightLimit];
        transmitted = new boolean[settings.lightLimit + 1];
        leaving = new boolean[settings.lightLimit];
        fades = new float[settings.lightLimit];
        meshHashes = new int[settings.lightLimit];
        // Depth comparisons remain at texel centres; RGB cache slices use filtering.
        atlas = texture(width, height, GL30.GL_RGBA16F, true);
        // Only shadow tiles and transmission caches are rendered with this target.
        depth = texture(width, hueStart, GL14.GL_DEPTH_COMPONENT24, false);
        shadowFramebuffer = GL30.glGenFramebuffers();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, shadowFramebuffer);
        GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_COLOR_ATTACHMENT0, GL11.GL_TEXTURE_2D, atlas, 0);
        GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_DEPTH_ATTACHMENT, GL11.GL_TEXTURE_2D, depth, 0);
        GL11.glDrawBuffer(GL30.GL_COLOR_ATTACHMENT0);
        checkFramebuffer();
        voxelTexture = texture(settings.size * 8, settings.size * ((settings.size + 7) / 8), GL30.GL_RGBA16F, false);
        absorptionTexture = texture(settings.size * 8, settings.size * ((settings.size + 7) / 8), GL30.GL_RGBA16F, false);
        shadowProgram = program("shadow.vsh", "shadow.fsh");
        transmissionProgram = program("fullscreen.vsh", "transmission.fsh");
        injectProgram = program("fullscreen.vsh", "inject.fsh");
        propagateProgram = program("fullscreen.vsh", "propagate.fsh");
        accumulateProgram = program("fullscreen.vsh", "accumulate.fsh");
        packProgram = program("fullscreen.vsh", "pack.fsh");
        meshArray = GL30.glGenVertexArrays();
        meshBuffer = GL15.glGenBuffers();
        glassArray = GL30.glGenVertexArrays();
        glassBuffer = GL15.glGenBuffers();
        lightArray = GL30.glGenVertexArrays();
        lightBuffer = GL15.glGenBuffers();
        lightGlassArray = GL30.glGenVertexArrays();
        lightGlassBuffer = GL15.glGenBuffers();
        quadArray = GL30.glGenVertexArrays();
        int[][] meshes = {{meshArray, meshBuffer}, {glassArray, glassBuffer},
                          {lightArray, lightBuffer}, {lightGlassArray, lightGlassBuffer}};
        for (int[] mesh : meshes) {
            GL30.glBindVertexArray(mesh[0]);
            GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, mesh[1]);
            GL20.glEnableVertexAttribArray(0);
            GL20.glVertexAttribPointer(0, 4, GL11.GL_FLOAT, false, 16, 0L);
        }
        for (int index = 0; index < 2; index++) {
            steps[index] = new Field();
            sums[index] = new Field();
            totals[index] = new Field();
            packed[index] = texture((settings.size + 2) * 8,
                (settings.size + 2) * ((settings.size + 7) / 8) * 3, GL30.GL_RGBA16F, true);
        }
        previousBounce = new Field();
        packedFramebuffer = GL30.glGenFramebuffers();
        CompanionMod.LOGGER.info("SIMPLE_LIGHTING GPU resources size={} lights={} shadow={}",
            settings.size, settings.lightLimit, settings.shadowResolution);
    }

    /** A block edit may open or close coloured light paths through its section. */
    void invalidateHue(long section) {
        hue.invalidate(section);
    }

    /** Floods run on a worker; publish each finished one. Slots are stable, so
     * only changed bricks are uploaded. */
    void setHueSources(ClientLevel level, List<ColourSources.Source> value, Vec3 camera) {
        HueVolume.Result result = hue.poll(level, value, camera);
        if (result == null) {
            return;
        }
        if (result.millis() >= 20) {
            CompanionMod.LOGGER.info("SIMPLE_LIGHTING coloured light flood {} ms", result.millis());
        }
        hueX = result.originX();
        hueY = result.originY();
        hueZ = result.originZ();
        uploadHue(result);
        bindingRevision++;
        if (!hueValid) {
            hueValid = true;
            if (scene != null) {
                metadata();
            }
        }
    }

    /** Coloured lighting off: the shader keeps the native block-light tint. */
    void clearHue() {
        if (!hueValid) {
            return;
        }
        hueValid = false;
        hue.invalidateAll();
        if (scene != null) {
            metadata();
        }
    }

    private void uploadHue(HueVolume.Result result) {
        bindTexture(0, atlas);
        int rows = poolStart - hueStart;
        float[] indirection = new float[rows * width * 4];
        System.arraycopy(result.indirection(), 0, indirection, 0, result.indirection().length);
        GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, 0, hueStart, width, rows, GL11.GL_RGBA, GL11.GL_FLOAT, indirection);
        int side = HueVolume.BRICK * HueVolume.BRICK;
        int perRow = width / side;
        for (int index = 0; index < result.slots().length; index++) {
            int slot = result.slots()[index];
            GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, (slot % perRow) * side,
                poolStart + (slot / perRow) * HueVolume.BRICK, side, HueVolume.BRICK,
                GL11.GL_RGBA, GL11.GL_FLOAT, result.bricks()[index]);
        }
    }

    boolean ready() { return scene != null; }

    /** Publish point lights immediately and preserve the preceding complete GI volume. */
    void setScene(SceneVolume value, Vector3f direction, Vector3f color, ShaderSettings settings) {
        if (value.sameContent(scene)
            && sceneSettings.bounces == settings.bounces && sceneSettings.reflectance == settings.reflectance
            && sceneSettings.blockStrength == settings.blockStrength
            && sceneSettings.propagationSteps == settings.propagationSteps) {
            // About 1.1 degrees or a 2% colour change. Sun motion alone only
            // redraws the sun tile and restarts GI; point-light maps stay valid.
            if (direction.distanceSquared(sunDirection) < 0.0004f
                && color.distanceSquared(publishedSunColor) <= 0.0004f * publishedSunColor.lengthSquared()) {
                return;
            }
            sunDirection.set(direction);
            sunColor.set(color);
            publishedSunColor.set(color);
            sunRendered = false;
            calculating = false;
            iteration = 0;
            return;
        }
        SceneVolume previous = scene;
        scene = value;
        sceneSettings = settings;
        bindingRevision++;
        sunDirection.set(direction);
        sunColor.set(color);
        publishedSunColor.set(color);
        float[] mesh = value.mesh();
        vertices = mesh.length / 4;
        GL30.glBindVertexArray(meshArray);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, meshBuffer);
        GL15.glBufferData(GL15.GL_ARRAY_BUFFER, mesh, GL15.GL_STATIC_DRAW);
        float[] glass = value.glassMesh();
        glassVertices = glass.length / 4;
        GL30.glBindVertexArray(glassArray);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, glassBuffer);
        GL15.glBufferData(GL15.GL_ARRAY_BUFFER, glass, GL15.GL_STATIC_DRAW);
        int n = value.size;
        int atlasWidth = n * 8;
        float[] data = new float[atlasWidth * n * ((n + 7) / 8) * 4];
        float[] absorption = new float[data.length];
        for (int z = 0; z < n; z++) {
            for (int y = 0; y < n; y++) {
                for (int x = 0; x < n; x++) {
                    int source = ((z * n + y) * n + x) * 4;
                    int destination = (((z / 8) * n + y) * atlasWidth + (z % 8) * n + x) * 4;
                    System.arraycopy(value.voxels, source, data, destination, 4);
                    System.arraycopy(value.absorption, source, absorption, destination, 4);
                }
            }
        }
        bindTexture(0, voxelTexture);
        GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, 0, 0, atlasWidth,
            n * ((n + 7) / 8), GL11.GL_RGBA, GL11.GL_FLOAT, data);
        bindTexture(0, absorptionTexture);
        GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, 0, 0, atlasWidth,
            n * ((n + 7) / 8), GL11.GL_RGBA, GL11.GL_FLOAT, absorption);
        iteration = 0;
        calculating = false;
        sunRendered = false;
        if (previous == null) {
            GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, shadowFramebuffer);
            GL11.glDisable(GL11.GL_SCISSOR_TEST);
            GL11.glClearColor(1, 1, 1, 1);
            GL11.glDepthMask(true);
            GL11.glClearDepth(1.0);
            GL11.glClear(GL11.GL_COLOR_BUFFER_BIT | GL11.GL_DEPTH_BUFFER_BIT);
        }
        restale(previous, value);
        metadata();
    }

    /** Point-light maps belong to their lights and survive volume moves. Occluder
     * changes seen by the scan redraw the lights that reach them; glass caches
     * cover the radiance volume and follow it.
     */
    private void restale(SceneVolume previous, SceneVolume next) {
        List<long[]> changes = previous == null ? List.of() : changes(previous, next);
        boolean moved = previous == null || previous.originX != next.originX
            || previous.originY != next.originY || previous.originZ != next.originZ;
        transmissionQueue.clear();
        for (int slot = 0; slot < slotCount; slot++) {
            PointLight light = slots[slot];
            if (light == null || !mapped[slot]) {
                continue;
            }
            if (affected(light, changes)) {
                queueShadow(slot, false);
            } else if (next.transmittingCells > 0 && (moved || !transmitted[slot]) && reachesVolume(light)) {
                transmissionQueue.add(slot);
            }
        }
    }

    /** Shadowed lights are the nearest emitters by reach-weighted distance,
     * wherever the radiance volume is. Re-selected when the emitters change or
     * the camera moves a block.
     */
    void setLights(ClientLevel world, List<ColourSources.Source> sources, Vec3 camera, ShaderSettings settings) {
        if (scene == null) {
            return;
        }
        level = world;
        if (sources == lightSources && camera.distanceToSqr(lightCamera) < 1.0
            && settings.coloured == lightColoured && settings.radius == lightRadius) {
            return;
        }
        lightSources = sources;
        lightCamera = camera;
        lightColoured = settings.coloured;
        lightRadius = settings.radius;
        // Bounded max-heap: the farthest kept candidate is replaced first.
        PriorityQueue<double[]> nearest = new PriorityQueue<>((a, b) -> Double.compare(b[0], a[0]));
        for (int index = 0; index < sources.size(); index++) {
            ColourSources.Source source = sources.get(index);
            double dx = source.x() + 0.5 - camera.x;
            double dy = source.y() + 0.5 - camera.y;
            double dz = source.z() + 0.5 - camera.z;
            double score = (dx * dx + dy * dy + dz * dz)
                / Math.max(PointLight.radius(source.emission(), settings), 1.0f);
            if (nearest.size() < slots.length) {
                nearest.add(new double[] {score, index});
            } else if (score < nearest.peek()[0]) {
                nearest.poll();
                nearest.add(new double[] {score, index});
            }
        }
        List<double[]> chosen = new ArrayList<>(nearest);
        chosen.sort(Comparator.comparingDouble(entry -> entry[0]));
        Arrays.fill(leaving, true);
        waiting.clear();
        for (double[] entry : chosen) {
            PointLight light = PointLight.of(sources.get((int) entry[1]), settings);
            int slot = 0;
            while (slot < slots.length && (slots[slot] == null || !slots[slot].sameMap(light))) {
                slot++;
            }
            if (slot < slots.length) {
                // Colour may change with the coloured-lighting option; the map stays.
                slots[slot] = light;
                leaving[slot] = false;
            } else {
                waiting.add(light);
            }
        }
    }

    /** Fade slots toward their state, release faded-out slots and fill free ones. */
    private boolean updateSlots(float step) {
        boolean changed = false;
        for (int slot = 0; slot < slots.length; slot++) {
            if (slots[slot] == null) {
                continue;
            }
            float target = leaving[slot] || !mapped[slot] ? 0.0f : 1.0f;
            float fade = target > fades[slot] ? Math.min(target, fades[slot] + step)
                : Math.max(target, fades[slot] - step);
            changed |= fade != fades[slot];
            fades[slot] = fade;
            if (leaving[slot] && fade <= 0.0f) {
                if (mapped[slot] && reachesVolume(slots[slot])) {
                    restartGi();
                }
                slots[slot] = null;
                mapped[slot] = false;
                shadowQueue.remove((Integer) slot);
                transmissionQueue.remove((Integer) slot);
                changed = true;
            }
        }
        for (int slot = 0; slot < slots.length && !waiting.isEmpty(); slot++) {
            if (slots[slot] == null) {
                slots[slot] = waiting.removeFirst();
                mapped[slot] = false;
                leaving[slot] = false;
                fades[slot] = 0.0f;
                shadowQueue.add(slot);
                changed = true;
            }
        }
        slotCount = 0;
        for (int slot = 0; slot < slots.length; slot++) {
            if (slots[slot] != null) {
                slotCount = slot + 1;
            }
        }
        return changed;
    }

    /** A block edit redraws, first, the maps of lights that reach its section. */
    void invalidateLights(long section) {
        int x = SectionPos.x(section) * 16;
        int y = SectionPos.y(section) * 16;
        int z = SectionPos.z(section) * 16;
        for (int slot = 0; slot < slotCount; slot++) {
            if (slots[slot] != null && mapped[slot] && slots[slot].reaches(x, y, z, x + 16, y + 16, z + 16)) {
                queueShadow(slot, true);
            }
        }
    }

    private void queueShadow(int slot, boolean first) {
        if (first) {
            shadowQueue.remove((Integer) slot);
            shadowQueue.addFirst(slot);
        } else if (!shadowQueue.contains(slot)) {
            shadowQueue.add(slot);
        }
    }

    /** Only lights reaching the radiance volume feed GI and its glass caches. */
    private boolean reachesVolume(PointLight light) {
        return light.reaches(scene.originX, scene.originY, scene.originZ,
            scene.originX + scene.size, scene.originY + scene.size, scene.originZ + scene.size);
    }

    /** GI keeps the published volume and recomputes once the map queues drain. */
    private void restartGi() {
        calculating = false;
        iteration = 0;
    }

    /** World cells whose shadow geometry differs between two snapshots. */
    private static List<long[]> changes(SceneVolume previous, SceneVolume next) {
        List<long[]> result = new ArrayList<>();
        compare(next, previous, result, true);
        compare(previous, next, result, false);
        return result;
    }

    private static void compare(SceneVolume from, SceneVolume other, List<long[]> result, boolean overlap) {
        int n = from.size;
        for (int index = 0; index < from.occluders.length; index++) {
            int x = from.originX + index % n;
            int y = from.originY + (index / n) % n;
            int z = from.originZ + index / (n * n);
            boolean inside = x >= other.originX && y >= other.originY && z >= other.originZ
                && x < other.originX + n && y < other.originY + n && z < other.originZ + n;
            BlockState state = from.occluders[index];
            if (overlap ? state != other.occluder(x, y, z) : !inside && state != null) {
                result.add(new long[] {x, y, z});
            }
        }
    }

    private static boolean affected(PointLight light, List<long[]> changes) {
        double x = light.x() + light.offsetX();
        double y = light.y() + light.offsetY();
        double z = light.z() + light.offsetZ();
        double reach = (light.radius() + 1.0) * (light.radius() + 1.0);
        for (long[] cell : changes) {
            double dx = cell[0] + 0.5 - x;
            double dy = cell[1] + 0.5 - y;
            double dz = cell[2] + 0.5 - z;
            if (dx * dx + dy * dy + dz * dz <= reach) {
                return true;
            }
        }
        return false;
    }

    /** Budget shadow-map work and GI propagation independently across frames. */
    void advance(ShaderSettings settings) {
        if (scene == null) { return; }
        long now = System.nanoTime();
        float elapsed = lastAdvance == 0 ? 0.0f : Math.min((now - lastAdvance) / 1.0e9f, 0.1f);
        lastAdvance = now;
        boolean changed = updateSlots(elapsed / FADE_SECONDS);
        if (!sunRendered) {
            renderSun();
            sunRendered = true;
            changed = true;
        }
        for (int work = 0; work < settings.shadowUpdates && !shadowQueue.isEmpty(); work++) {
            int slot = shadowQueue.removeFirst();
            renderLight(slot, slots[slot].gather(level));
            changed = true;
        }
        // Volume moves only shift the scene-local transmission caches; four per map budget.
        for (int work = 0; work < settings.shadowUpdates * 4 && !transmissionQueue.isEmpty(); work++) {
            PointLight light = slots[transmissionQueue.peekFirst()];
            renderTransmission(transmissionQueue.removeFirst(), local(light), light.radius(), false);
            changed = true;
        }
        // Edits beyond the scan and the player's reach are found by re-gathering
        // one mapped light at a time; only a changed mesh is redrawn.
        refreshDue = Math.min(refreshDue + elapsed * slotCount / REFRESH_SECONDS, 1.0f);
        if (refreshDue >= 1.0f && shadowQueue.isEmpty() && slotCount > 0) {
            refreshDue = 0.0f;
            refreshCursor = (refreshCursor + 1) % slotCount;
            if (slots[refreshCursor] != null && mapped[refreshCursor]) {
                PointLight.Mesh mesh = slots[refreshCursor].gather(level);
                if (mesh.hash() != meshHashes[refreshCursor]) {
                    renderLight(refreshCursor, mesh);
                    changed = true;
                }
            }
        }
        if (shadowQueue.isEmpty() && transmissionQueue.isEmpty() && !calculating && iteration == 0) {
            beginGi(settings);
        }
        for (int work = 0; work < settings.workPerFrame && calculating; work++) {
            giStep(settings);
            changed = true;
        }
        if (changed) {
            metadata();
        }
    }

    /** Maps are rendered in the light's block frame, so they never depend on the volume. */
    private void renderLight(int index, PointLight.Mesh mesh) {
        PointLight light = slots[index];
        mapped[index] = true;
        meshHashes[index] = mesh.hash();
        upload(lightArray, lightBuffer, mesh.opaque());
        upload(lightGlassArray, lightGlassBuffer, mesh.glass());
        Vector3f eye = new Vector3f(light.offsetX(), light.offsetY(), light.offsetZ());
        Vector3f[] directions = {new Vector3f(1,0,0),new Vector3f(-1,0,0),new Vector3f(0,1,0),
                                new Vector3f(0,-1,0),new Vector3f(0,0,1),new Vector3f(0,0,-1)};
        Vector3f[] ups = {new Vector3f(0,-1,0),new Vector3f(0,-1,0),new Vector3f(0,0,1),
                         new Vector3f(0,0,-1),new Vector3f(0,-1,0),new Vector3f(0,-1,0)};
        for (int face = 0; face < 6; face++) {
            Matrix4f view = new Matrix4f().lookAt(eye, new Vector3f(eye).add(directions[face]), ups[face]);
            Matrix4f matrix = new Matrix4f().perspective((float)Math.PI / 2, 1, 0.04f, light.radius()).mul(view);
            shadowTile(index * 6 + face, matrix, eye, light.radius(), lightArray, mesh.opaque().length / 4,
                lightGlassArray, mesh.glass().length / 4, false);
        }
        if (reachesVolume(light)) {
            renderTransmission(index, local(light), light.radius(), false);
            restartGi();
        } else {
            transmitted[index] = false;
        }
    }

    /** Light position in the radiance volume frame. */
    private Vector3f local(PointLight light) {
        return new Vector3f(light.x() - scene.originX + light.offsetX(), light.y() - scene.originY + light.offsetY(),
            light.z() - scene.originZ + light.offsetZ());
    }

    private static void upload(int array, int buffer, float[] vertices) {
        GL30.glBindVertexArray(array);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, buffer);
        GL15.glBufferData(GL15.GL_ARRAY_BUFFER, vertices, GL15.GL_STREAM_DRAW);
    }

    private void renderSun() {
        float half = scene.size * 0.5f;
        Vector3f center = new Vector3f(half);
        Vector3f eye = new Vector3f(sunDirection).mul(scene.size * 3.0f).add(center);
        Vector3f up = Math.abs(sunDirection.y) > 0.95f ? new Vector3f(0,0,1) : new Vector3f(0,1,0);
        float extent = scene.size * 0.88f;
        sunMatrix.identity().ortho(-extent, extent, -extent, extent, 0.1f, scene.size * 6.0f)
            .mul(new Matrix4f().lookAt(eye, center, up));
        shadowTile(resources.lightLimit * 6, sunMatrix, eye, scene.size * 6.0f, meshArray, vertices,
            glassArray, glassVertices, true);
        renderTransmission(resources.lightLimit, eye, scene.size * 6.0f, true);
    }

    private void shadowTile(int tile, Matrix4f matrix, Vector3f eye, float radius, int array, int count,
                            int glass, int glassCount, boolean directional) {
        int side = resources.shadowResolution;
        int x = (tile % TILES_ACROSS) * side;
        int y = HEADER + (tile / TILES_ACROSS) * side;
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, shadowFramebuffer);
        GL11.glDrawBuffer(GL30.GL_COLOR_ATTACHMENT0);
        GL11.glEnable(GL11.GL_SCISSOR_TEST);
        GL11.glScissor(x, y, side, side);
        GL11.glViewport(x + 1, y + 1, side - 2, side - 2);
        GL11.glEnable(GL11.GL_DEPTH_TEST);
        GL11.glDepthFunc(GL11.GL_LESS);
        GL11.glDepthMask(true);
        GL11.glColorMask(true, true, true, true);
        GL11.glClearColor(1, 1, 1, 1);
        GL11.glClearDepth(1.0);
        GL11.glClear(GL11.GL_COLOR_BUFFER_BIT | GL11.GL_DEPTH_BUFFER_BIT);
        GL20.glUseProgram(shadowProgram);
        matrix(shadowProgram, "uLightMatrix", matrix);
        vector(shadowProgram, "uLightPosition", eye);
        scalar(shadowProgram, "uLightRadius", radius);
        // Emitter blocks are left out of their own meshes; no owner is discarded.
        integer(shadowProgram, "uLightOwner", -1);
        integer(shadowProgram, "uDirectional", directional ? 1 : 0);
        integer(shadowProgram, "uTransmissionPass", 0);
        GL30.glBindVertexArray(array);
        GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, count);
        if (glassCount > 0) {
            // Store first glass depth in G without changing opaque depth in R.
            GL11.glClear(GL11.GL_DEPTH_BUFFER_BIT);
            GL11.glColorMask(false, true, false, false);
            integer(shadowProgram, "uTransmissionPass", 1);
            GL30.glBindVertexArray(glass);
            GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, glassCount);
            GL11.glColorMask(true, true, true, true);
        }
    }

    /** Cache receiver-dependent RGB absorption once per light and scene update. */
    private void renderTransmission(int index, Vector3f position, float radius, boolean directional) {
        transmitted[index] = scene.transmittingCells > 0;
        if (!transmitted[index]) {
            return;
        }
        int x = (index % transmissionColumns) * transmissionWidth;
        int y = transmissionStart + (index / transmissionColumns) * transmissionHeight;
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, shadowFramebuffer);
        GL11.glDrawBuffer(GL30.GL_COLOR_ATTACHMENT0);
        GL11.glDisable(GL11.GL_DEPTH_TEST);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL11.glViewport(x, y, transmissionWidth, transmissionHeight);
        GL20.glUseProgram(transmissionProgram);
        bindTexture(7, absorptionTexture);
        integer(transmissionProgram, "uAbsorption", 7);
        integer(transmissionProgram, "uSize", resources.size);
        GL20.glUniform2i(location(transmissionProgram, "uTileOrigin"), x, y);
        vector(transmissionProgram, "uLightPosition", position);
        vector(transmissionProgram, "uSunDirection", sunDirection);
        scalar(transmissionProgram, "uLightRadius", radius);
        integer(transmissionProgram, "uDirectional", directional ? 1 : 0);
        draw();
    }

    private void beginGi(ShaderSettings settings) {
        iteration = 0;
        bounce = 0;
        currentStep = currentSum = currentTotal = 0;
        if (settings.bounces == 0) {
            giValid = false;
            iteration = -1;
            return;
        }
        for (Field field : sums) { field.clear(); }
        for (Field field : totals) { field.clear(); }
        previousBounce.clear();
        calculating = true;
    }

    private void giStep(ShaderSettings settings) {
        if (iteration == 0) {
            target(steps[0]);
            setup(injectProgram, previousBounce, null);
            integer(injectProgram, "uBounce", bounce);
            scalar(injectProgram, "uReflectance", settings.reflectance);
            scalar(injectProgram, "uBlockStrength", settings.blockStrength);
            vector(injectProgram, "uSunDirection", sunDirection);
            vector(injectProgram, "uSunColor", sunColor);
            matrix(injectProgram, "uSunMatrix", sunMatrix);
            draw();
            currentStep = 0;
        } else {
            target(steps[1-currentStep]);
            setup(propagateProgram, steps[currentStep], null);
            draw();
            currentStep = 1-currentStep;
        }
        target(sums[1-currentSum]);
        setup(accumulateProgram, steps[currentStep], sums[currentSum]);
        draw();
        currentSum = 1-currentSum;
        iteration++;
        if (iteration < settings.propagationSteps) { return; }
        target(totals[1-currentTotal]);
        setup(accumulateProgram, totals[currentTotal], sums[currentSum]);
        draw();
        currentTotal = 1-currentTotal;
        copy(sums[currentSum], previousBounce);
        bounce++;
        if (bounce < settings.bounces) {
            for (Field field : sums) { field.clear(); }
            currentSum = 0;
            iteration = 0;
            return;
        }
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, packedFramebuffer);
        GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_COLOR_ATTACHMENT0,
                                    GL11.GL_TEXTURE_2D, packed[1-currentPacked], 0);
        GL11.glDrawBuffer(GL30.GL_COLOR_ATTACHMENT0);
        GL11.glViewport(0, 0, (resources.size+2)*8, (resources.size+2)*((resources.size+7)/8)*3);
        setup(packProgram, totals[currentTotal], null);
        draw();
        currentPacked = 1-currentPacked;
        giOriginX = scene.originX;
        giOriginY = scene.originY;
        giOriginZ = scene.originZ;
        bindingRevision++;
        giValid = true;
        calculating = false;
        iteration = -1;
        // Record initialization and configuration changes without logging every update.
        if (loggedBounces != settings.bounces || loggedLights != slotCount) {
            CompanionMod.LOGGER.info("SIMPLE_LIGHTING GI published bounces={} lights={}",
                settings.bounces, slotCount);
            loggedBounces = settings.bounces;
            loggedLights = slotCount;
        }
    }

    /** Texture header records valid point-map count, atlas layout and volume shape. */
    private void metadata() {
        float[] data = header;
        java.util.Arrays.fill(data, 0.0f);
        data[0] = 2026;
        data[1] = slotCount;
        data[2] = resources.size;
        data[3] = giValid ? 1 : 0;
        data[4] = width;
        data[5] = height;
        data[6] = resources.shadowResolution;
        data[7] = TILES_ACROSS;
        // Layout version: 4 anchors lights to their block in three-texel records.
        data[8] = 4;
        data[9] = transmissionStart;
        data[10] = transmissionColumns;
        data[11] = scene.transmittingCells > 0 ? 1 : 0;
        data[12] = resources.lightLimit;
        data[13] = hueStart;
        data[14] = hueValid ? 1 : 0;
        data[15] = sunRendered ? 1 : 0;
        for (int index = 0; index < slotCount; index++) {
            PointLight light = slots[index];
            if (light == null) {
                continue;
            }
            // The atlas is half float: the block cell relative to the volume origin
            // stays an exact integer far from the camera, the in-block offset keeps
            // full precision in its own texel.
            int p = 16 + index * LIGHT_STRIDE;
            data[p] = light.x() - scene.originX;
            data[p+1] = light.y() - scene.originY;
            data[p+2] = light.z() - scene.originZ;
            data[p+3] = mapped[index] ? light.radius() : -light.radius();
            data[p+4] = light.r();
            data[p+5] = light.g();
            data[p+6] = light.b();
            data[p+7] = light.emission();
            data[p+8] = light.offsetX();
            data[p+9] = light.offsetY();
            data[p+10] = light.offsetZ();
            data[p+11] = fades[index];
        }
        bindTexture(0, atlas);
        GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, 0, 0, data.length/4, 1, GL11.GL_RGBA, GL11.GL_FLOAT, data);
    }

    int atlasTexture() { return atlas; }
    int radianceTexture() { return packed[currentPacked]; }
    long bindingRevision() { return bindingRevision; }

    void bind(int program, ShaderSettings.CameraFrame frame) {
        int ready = GL20.glGetUniformLocation(program, "companionReady");
        if (ready < 0) { return; }
        GL20.glUniform1i(ready, scene == null ? 0 : 1);
        if (scene == null) { return; }
        int active = GL11.glGetInteger(GL13.GL_ACTIVE_TEXTURE);
        bindTexture(12, atlas);
        bindTexture(14, packed[currentPacked]);
        GL20.glUniform1i(GL20.glGetUniformLocation(program, "companionAtlas"), 12);
        GL20.glUniform1i(GL20.glGetUniformLocation(program, "companionRadiance"), 14);
        GL20.glUniform2f(GL20.glGetUniformLocation(program, "companionDimensions"), width, height);
        // Snapshot coordinates stay absolute on the CPU. Shader coordinates use OptiFine's frame.
        GL20.glUniform3f(GL20.glGetUniformLocation(program, "companionOrigin"),
            scene.originX - frame.x(), scene.originY, scene.originZ - frame.z());
        GL20.glUniform3f(GL20.glGetUniformLocation(program, "companionGiOrigin"),
            giOriginX - frame.x(), giOriginY, giOriginZ - frame.z());
        GL20.glUniform3f(GL20.glGetUniformLocation(program, "companionHueOrigin"),
            hueX - frame.x(), hueY, hueZ - frame.z());
        GL13.glActiveTexture(active);
    }

    private void setup(int program, Field field, Field seed) {
        GL11.glDisable(GL11.GL_DEPTH_TEST);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL20.glUseProgram(program);
        bindTexture(0,atlas);
        bindTexture(1,voxelTexture);
        integer(program,"uShadowAtlas",0);
        integer(program,"uVoxels",1);
        integer(program,"uSize",resources.size);
        integer(program,"uResolution",resources.shadowResolution);
        integer(program,"uTilesAcross",TILES_ACROSS);
        integer(program,"uSunTile",resources.lightLimit*6);
        integer(program,"uLightCount",slotCount);
        GL20.glUniform2i(location(program,"uAtlasSize"),width,height);
        for (int band=0;band<3;band++) {
            if (field != null) { bindTexture(2+band,field.textures[band]); }
            if (seed != null) { bindTexture(5+band,seed.textures[band]); }
            integer(program,"uField"+"RGB".charAt(band),2+band);
            integer(program,"uSeed"+"RGB".charAt(band),5+band);
        }
        if (program == injectProgram || program == propagateProgram) {
            // These passes have no seed field, leaving saved texture unit 7 free.
            bindTexture(7, absorptionTexture);
            integer(program, "uAbsorption", 7);
        }
    }

    private void target(Field field) {
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER,field.framebuffer);
        GL20.glDrawBuffers(new int[] {GL30.GL_COLOR_ATTACHMENT0,GL30.GL_COLOR_ATTACHMENT1,GL30.GL_COLOR_ATTACHMENT2});
        GL11.glViewport(0,0,resources.size*8,resources.size*((resources.size+7)/8));
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
    }

    private void draw() {
        GL30.glBindVertexArray(quadArray);
        GL11.glDrawArrays(GL11.GL_TRIANGLES,0,3);
    }

    private void copy(Field source,Field target) {
        GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER,source.framebuffer);
        GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER,target.framebuffer);
        int w=resources.size*8, h=resources.size*((resources.size+7)/8);
        for (int band=0;band<3;band++) {
            GL11.glReadBuffer(GL30.GL_COLOR_ATTACHMENT0+band);
            GL11.glDrawBuffer(GL30.GL_COLOR_ATTACHMENT0+band);
            GL30.glBlitFramebuffer(0,0,w,h,0,0,w,h,GL11.GL_COLOR_BUFFER_BIT,GL11.GL_NEAREST);
        }
    }

    private int location(int program,String name) {
        return locations.computeIfAbsent(program,p -> new HashMap<>())
            .computeIfAbsent(name,n -> GL20.glGetUniformLocation(program,n));
    }
    private void integer(int p,String n,int v) { GL20.glUniform1i(location(p,n),v); }
    private void scalar(int p,String n,float v) { GL20.glUniform1f(location(p,n),v); }
    private void vector(int p,String n,Vector3f v) { GL20.glUniform3f(location(p,n),v.x,v.y,v.z); }
    private void matrix(int p,String n,Matrix4f v) { GL20.glUniformMatrix4fv(location(p,n),false,v.get(new float[16])); }
    private static void bindTexture(int unit,int texture) {
        GL13.glActiveTexture(GL13.GL_TEXTURE0+unit);
        GL11.glBindTexture(GL11.GL_TEXTURE_2D,texture);
    }
    private static int texture(int width,int height,int format,boolean linear) {
        int texture=GL11.glGenTextures();
        GL11.glBindTexture(GL11.GL_TEXTURE_2D,texture);
        boolean depth=format==GL14.GL_DEPTH_COMPONENT24;
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D,0,format,width,height,0,
            depth ? GL11.GL_DEPTH_COMPONENT : GL11.GL_RGBA,GL11.GL_FLOAT,(java.nio.ByteBuffer)null);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D,GL11.GL_TEXTURE_MIN_FILTER,linear ? GL11.GL_LINEAR : GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D,GL11.GL_TEXTURE_MAG_FILTER,linear ? GL11.GL_LINEAR : GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D,GL11.GL_TEXTURE_WRAP_S,GL12.GL_CLAMP_TO_EDGE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D,GL11.GL_TEXTURE_WRAP_T,GL12.GL_CLAMP_TO_EDGE);
        return texture;
    }
    private static void checkFramebuffer() {
        if (GL30.glCheckFramebufferStatus(GL30.GL_FRAMEBUFFER)!=GL30.GL_FRAMEBUFFER_COMPLETE) {
            throw new IllegalStateException("Incomplete local-light framebuffer");
        }
    }
    private static String source(String name) {
        try (var input=GpuLighting.class.getResourceAsStream("/lighting/"+name)) {
            if (input==null) { throw new IOException(name); }
            String value=new String(input.readAllBytes(),StandardCharsets.UTF_8);
            for (String include : new String[] {"volume.glsl", "optics.glsl", "transmission_lookup.glsl"}) {
                String directive = "#include \"" + include + "\"";
                if (value.contains(directive)) {
                    value = value.replace(directive, source(include));
                }
            }
            return value;
        } catch (IOException error) { throw new IllegalStateException(error); }
    }
    private static int program(String vertex,String fragment) {
        int program=GL20.glCreateProgram();
        int v=compile(GL20.GL_VERTEX_SHADER,source(vertex));
        int f=compile(GL20.GL_FRAGMENT_SHADER,source(fragment));
        GL20.glAttachShader(program,v);
        GL20.glAttachShader(program,f);
        GL20.glLinkProgram(program);
        if (GL20.glGetProgrami(program,GL20.GL_LINK_STATUS)==0) {
            throw new IllegalStateException(GL20.glGetProgramInfoLog(program));
        }
        GL20.glDeleteShader(v);
        GL20.glDeleteShader(f);
        return program;
    }
    private static int compile(int type,String source) {
        int shader=GL20.glCreateShader(type);
        GL20.glShaderSource(shader,source);
        GL20.glCompileShader(shader);
        if (GL20.glGetShaderi(shader,GL20.GL_COMPILE_STATUS)==0) {
            throw new IllegalStateException(GL20.glGetShaderInfoLog(shader));
        }
        return shader;
    }
    @Override
    public void close() {
        hue.close();
        for (Field field:steps) { field.delete(); }
        for (Field field:sums) { field.delete(); }
        for (Field field:totals) { field.delete(); }
        previousBounce.delete();
        for (int texture:new int[] {atlas,depth,voxelTexture,absorptionTexture,packed[0],packed[1]}) { GL11.glDeleteTextures(texture); }
        for (int program:new int[] {shadowProgram,transmissionProgram,injectProgram,propagateProgram,accumulateProgram,packProgram}) { GL20.glDeleteProgram(program); }
        GL30.glDeleteFramebuffers(shadowFramebuffer);
        GL30.glDeleteFramebuffers(packedFramebuffer);
        GL30.glDeleteVertexArrays(meshArray);
        GL30.glDeleteVertexArrays(quadArray);
        GL15.glDeleteBuffers(meshBuffer);
        GL15.glDeleteBuffers(glassBuffer);
        GL30.glDeleteVertexArrays(glassArray);
        GL15.glDeleteBuffers(lightBuffer);
        GL30.glDeleteVertexArrays(lightArray);
        GL15.glDeleteBuffers(lightGlassBuffer);
        GL30.glDeleteVertexArrays(lightGlassArray);
    }
}
