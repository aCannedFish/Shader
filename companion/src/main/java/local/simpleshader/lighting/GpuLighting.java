package local.simpleshader.lighting;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.List;
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
    private final ShaderSettings resources;
    private final int width;
    private final int height;
    private final int transmissionStart;
    private final int transmissionColumns;
    private final int transmissionWidth;
    private final int transmissionHeight;
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
    private List<ColourSources.Source> colourSources = List.of();
    private final Vector3f publishedSunColor = new Vector3f();
    private ShaderSettings sceneSettings;
    private int vertices;
    private int glassVertices;
    private int shadowCursor;
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
        height = transmissionStart + ((settings.lightLimit + 1 + transmissionColumns - 1) / transmissionColumns) * transmissionHeight;
        // Depth comparisons remain at texel centres; RGB cache slices use filtering.
        atlas = texture(width, height, GL30.GL_RGBA16F, true);
        depth = texture(width, height, GL14.GL_DEPTH_COMPONENT24, false);
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
        quadArray = GL30.glGenVertexArrays();
        GL30.glBindVertexArray(meshArray);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, meshBuffer);
        GL20.glEnableVertexAttribArray(0);
        GL20.glVertexAttribPointer(0, 4, GL11.GL_FLOAT, false, 16, 0L);
        GL30.glBindVertexArray(glassArray);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, glassBuffer);
        GL20.glEnableVertexAttribArray(0);
        GL20.glVertexAttribPointer(0, 4, GL11.GL_FLOAT, false, 16, 0L);
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

    boolean hasShadowWork() {
        return scene != null && shadowCursor < scene.lights.size();
    }

    /** A second header row carries emitter hues across the visible loaded chunks. */
    void setColourSources(List<ColourSources.Source> value) {
        if (value.equals(colourSources)) {
            return;
        }
        colourSources = value;
        if (scene != null) {
            colourMetadata();
        }
    }

    boolean ready() { return scene != null; }

    /** Publish point lights immediately and preserve the preceding complete GI volume. */
    void setScene(SceneVolume value, Vector3f direction, Vector3f color, ShaderSettings settings) {
        if (value.sameContent(scene) && direction.distanceSquared(sunDirection) < 0.00001f
            && color.distanceSquared(publishedSunColor) < 0.00001f
            && sceneSettings.bounces == settings.bounces && sceneSettings.reflectance == settings.reflectance
            && sceneSettings.blockStrength == settings.blockStrength
            && sceneSettings.propagationSteps == settings.propagationSteps) {
            return;
        }
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
        shadowCursor = 0;
        iteration = 0;
        calculating = false;
        sunRendered = false;
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, shadowFramebuffer);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL11.glClearColor(1, 1, 1, 1);
        GL11.glDepthMask(true);
        GL11.glClearDepth(1.0);
        GL11.glClear(GL11.GL_COLOR_BUFFER_BIT | GL11.GL_DEPTH_BUFFER_BIT);
        metadata();
        colourMetadata();
    }

    /** Budget shadow-map work and GI propagation independently across frames. */
    void advance(ShaderSettings settings) {
        if (scene == null) { return; }
        if (!sunRendered) {
            renderSun();
            sunRendered = true;
        }
        int end = Math.min(shadowCursor + settings.shadowUpdates, scene.lights.size());
        while (shadowCursor < end) {
            renderLight(shadowCursor++);
        }
        if (shadowCursor == scene.lights.size() && !calculating && iteration == -1) {
            return;
        }
        if (shadowCursor == scene.lights.size() && !calculating) {
            beginGi(settings);
        }
        for (int work = 0; work < settings.workPerFrame && calculating; work++) {
            giStep(settings);
        }
        metadata();
    }

    private void renderLight(int index) {
        SceneVolume.Light light = scene.lights.get(index);
        Vector3f eye = new Vector3f(light.x(), light.y(), light.z());
        Vector3f[] directions = {new Vector3f(1,0,0),new Vector3f(-1,0,0),new Vector3f(0,1,0),
                                new Vector3f(0,-1,0),new Vector3f(0,0,1),new Vector3f(0,0,-1)};
        Vector3f[] ups = {new Vector3f(0,-1,0),new Vector3f(0,-1,0),new Vector3f(0,0,1),
                         new Vector3f(0,0,-1),new Vector3f(0,-1,0),new Vector3f(0,-1,0)};
        for (int face = 0; face < 6; face++) {
            Matrix4f view = new Matrix4f().lookAt(eye, new Vector3f(eye).add(directions[face]), ups[face]);
            Matrix4f matrix = new Matrix4f().perspective((float)Math.PI / 2, 1, 0.04f, light.radius()).mul(view);
            shadowTile(index * 6 + face, matrix, eye, light.radius(), light.owner(), false);
        }
        renderTransmission(index, eye, light.radius(), false);
    }

    private void renderSun() {
        float half = scene.size * 0.5f;
        Vector3f center = new Vector3f(half);
        Vector3f eye = new Vector3f(sunDirection).mul(scene.size * 3.0f).add(center);
        Vector3f up = Math.abs(sunDirection.y) > 0.95f ? new Vector3f(0,0,1) : new Vector3f(0,1,0);
        float extent = scene.size * 0.88f;
        sunMatrix.identity().ortho(-extent, extent, -extent, extent, 0.1f, scene.size * 6.0f)
            .mul(new Matrix4f().lookAt(eye, center, up));
        shadowTile(resources.lightLimit * 6, sunMatrix, eye, scene.size * 6.0f, -1, true);
        renderTransmission(resources.lightLimit, eye, scene.size * 6.0f, true);
    }

    private void shadowTile(int tile, Matrix4f matrix, Vector3f eye, float radius, int owner, boolean directional) {
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
        integer(shadowProgram, "uLightOwner", owner);
        integer(shadowProgram, "uDirectional", directional ? 1 : 0);
        integer(shadowProgram, "uTransmissionPass", 0);
        GL30.glBindVertexArray(meshArray);
        GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, vertices);
        if (glassVertices > 0) {
            // Store first glass depth in G without changing opaque depth in R.
            GL11.glClear(GL11.GL_DEPTH_BUFFER_BIT);
            GL11.glColorMask(false, true, false, false);
            integer(shadowProgram, "uTransmissionPass", 1);
            GL30.glBindVertexArray(glassArray);
            GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, glassVertices);
            GL11.glColorMask(true, true, true, true);
        }
    }

    /** Cache receiver-dependent RGB absorption once per light and scene update. */
    private void renderTransmission(int index, Vector3f position, float radius, boolean directional) {
        if (scene.transmittingCells == 0) {
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
        if (loggedBounces != settings.bounces || loggedLights != scene.lights.size()) {
            CompanionMod.LOGGER.info("SIMPLE_LIGHTING GI published bounces={} lights={}",
                settings.bounces, scene.lights.size());
            loggedBounces = settings.bounces;
            loggedLights = scene.lights.size();
        }
    }

    /** Texture header records valid point-map count, atlas layout and volume shape. */
    private void metadata() {
        float[] data = new float[resources.lightLimit * 8 + 16];
        data[0] = 2026;
        data[1] = scene.lights.size();
        data[2] = resources.size;
        data[3] = giValid ? 1 : 0;
        data[4] = width;
        data[5] = height;
        data[6] = resources.shadowResolution;
        data[7] = TILES_ACROSS;
        data[8] = 2;
        data[9] = transmissionStart;
        data[10] = transmissionColumns;
        data[11] = scene.transmittingCells > 0 ? 1 : 0;
        data[12] = resources.lightLimit;
        data[13] = colourSources.size();
        data[15] = sunRendered ? 1 : 0;
        for (int index = 0; index < scene.lights.size(); index++) {
            SceneVolume.Light light = scene.lights.get(index);
            int p = 16 + index * 8;
            data[p] = light.x();
            data[p+1] = light.y();
            data[p+2] = light.z();
            data[p+3] = index < shadowCursor ? light.radius() : -light.radius();
            data[p+4] = light.r();
            data[p+5] = light.g();
            data[p+6] = light.b();
        }
        bindTexture(0, atlas);
        GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, 0, 0, data.length/4, 1, GL11.GL_RGBA, GL11.GL_FLOAT, data);
    }

    /** Preserve integer precision by subtracting the snapshot origin before upload. */
    private void colourMetadata() {
        float[] data = new float[ColourSources.LIMIT * 8];
        for (int index = 0; index < colourSources.size(); index++) {
            ColourSources.Source source = colourSources.get(index);
            int offset = index * 8;
            data[offset] = source.x() - scene.originX + 0.5f;
            data[offset + 1] = source.y() - scene.originY + 0.72f;
            data[offset + 2] = source.z() - scene.originZ + 0.5f;
            data[offset + 3] = source.emission() + 1.0f;
            data[offset + 4] = source.r();
            data[offset + 5] = source.g();
            data[offset + 6] = source.b();
        }
        bindTexture(0, atlas);
        GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, 0, 1, ColourSources.LIMIT * 2, 1,
            GL11.GL_RGBA, GL11.GL_FLOAT, data);
        metadata();
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
        bindTexture(13, atlas);
        bindTexture(14, packed[currentPacked]);
        GL20.glUniform1i(GL20.glGetUniformLocation(program, "companionAtlas"), 13);
        GL20.glUniform1i(GL20.glGetUniformLocation(program, "companionRadiance"), 14);
        GL20.glUniform2f(GL20.glGetUniformLocation(program, "companionDimensions"), width, height);
        GL20.glUniformMatrix4fv(GL20.glGetUniformLocation(program, "companionSunMatrix"), false,
            sunMatrix.get(new float[16]));
        // Snapshot coordinates stay absolute on the CPU. Shader coordinates use OptiFine's frame.
        GL20.glUniform3f(GL20.glGetUniformLocation(program, "companionOrigin"),
            scene.originX - frame.x(), scene.originY, scene.originZ - frame.z());
        GL20.glUniform3f(GL20.glGetUniformLocation(program, "companionGiOrigin"),
            giOriginX - frame.x(), giOriginY, giOriginZ - frame.z());
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
        integer(program,"uLightCount",scene.lights.size());
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
    }
}
