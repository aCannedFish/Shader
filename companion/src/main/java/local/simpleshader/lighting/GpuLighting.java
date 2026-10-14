package local.simpleshader.lighting;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
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
    private final int atlas;
    private final int depth;
    private final int shadowFramebuffer;
    private final int voxelTexture;
    private final int shadowProgram;
    private final int injectProgram;
    private final int propagateProgram;
    private final int accumulateProgram;
    private final int packProgram;
    private final int meshArray;
    private final int meshBuffer;
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
    private int vertices;
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
        width = TILES_ACROSS * settings.shadowResolution;
        height = HEADER + ((settings.lightLimit * 6 + 1 + TILES_ACROSS - 1) / TILES_ACROSS) * settings.shadowResolution;
        atlas = texture(width, height, GL30.GL_RGBA16F, false);
        depth = texture(width, height, GL14.GL_DEPTH_COMPONENT24, false);
        shadowFramebuffer = GL30.glGenFramebuffers();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, shadowFramebuffer);
        GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_COLOR_ATTACHMENT0, GL11.GL_TEXTURE_2D, atlas, 0);
        GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_DEPTH_ATTACHMENT, GL11.GL_TEXTURE_2D, depth, 0);
        GL11.glDrawBuffer(GL30.GL_COLOR_ATTACHMENT0);
        checkFramebuffer();
        voxelTexture = texture(settings.size * 8, settings.size * ((settings.size + 7) / 8), GL30.GL_RGBA16F, false);
        shadowProgram = program("shadow.vsh", "shadow.fsh");
        injectProgram = program("fullscreen.vsh", "inject.fsh");
        propagateProgram = program("fullscreen.vsh", "propagate.fsh");
        accumulateProgram = program("fullscreen.vsh", "accumulate.fsh");
        packProgram = program("fullscreen.vsh", "pack.fsh");
        meshArray = GL30.glGenVertexArrays();
        meshBuffer = GL15.glGenBuffers();
        quadArray = GL30.glGenVertexArrays();
        GL30.glBindVertexArray(meshArray);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, meshBuffer);
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

    boolean hasWork() {
        return scene != null && (shadowCursor < scene.lights.size() || calculating);
    }

    boolean ready() { return scene != null; }

    /** Publish point lights immediately and preserve the preceding complete GI volume. */
    void setScene(SceneVolume value, Vector3f direction, Vector3f color, ShaderSettings settings) {
        scene = value;
        bindingRevision++;
        sunDirection.set(direction);
        sunColor.set(color);
        float[] mesh = value.mesh();
        vertices = mesh.length / 4;
        GL30.glBindVertexArray(meshArray);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, meshBuffer);
        GL15.glBufferData(GL15.GL_ARRAY_BUFFER, mesh, GL15.GL_STATIC_DRAW);
        int n = value.size;
        int atlasWidth = n * 8;
        float[] data = new float[atlasWidth * n * ((n + 7) / 8) * 4];
        for (int z = 0; z < n; z++) {
            for (int y = 0; y < n; y++) {
                for (int x = 0; x < n; x++) {
                    int source = ((z * n + y) * n + x) * 4;
                    int destination = (((z / 8) * n + y) * atlasWidth + (z % 8) * n + x) * 4;
                    System.arraycopy(value.voxels, source, data, destination, 4);
                }
            }
        }
        bindTexture(0, voxelTexture);
        GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, 0, 0, atlasWidth,
            n * ((n + 7) / 8), GL11.GL_RGBA, GL11.GL_FLOAT, data);
        shadowCursor = 0;
        iteration = 0;
        calculating = false;
        sunRendered = false;
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, shadowFramebuffer);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL11.glClearColor(1, 0, 0, 0);
        GL11.glDepthMask(true);
        GL11.glClearDepth(1.0);
        GL11.glClear(GL11.GL_COLOR_BUFFER_BIT | GL11.GL_DEPTH_BUFFER_BIT);
        metadata();
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
        GL11.glClearColor(1, 0, 0, 0);
        GL11.glClearDepth(1.0);
        GL11.glClear(GL11.GL_COLOR_BUFFER_BIT | GL11.GL_DEPTH_BUFFER_BIT);
        GL20.glUseProgram(shadowProgram);
        matrix(shadowProgram, "uLightMatrix", matrix);
        vector(shadowProgram, "uLightPosition", eye);
        scalar(shadowProgram, "uLightRadius", radius);
        integer(shadowProgram, "uLightOwner", owner);
        integer(shadowProgram, "uDirectional", directional ? 1 : 0);
        GL30.glBindVertexArray(meshArray);
        GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, vertices);
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

    int atlasTexture() { return atlas; }
    int radianceTexture() { return packed[currentPacked]; }
    long bindingRevision() { return bindingRevision; }

    void bind(int program) {
        int ready = GL20.glGetUniformLocation(program, "companionReady");
        if (ready < 0) { return; }
        GL20.glUniform1i(ready, scene == null ? 0 : 1);
        if (scene == null) { return; }
        int active = GL11.glGetInteger(GL13.GL_ACTIVE_TEXTURE);
        bindTexture(13, atlas);
        bindTexture(14, packed[currentPacked]);
        GL20.glUniform1i(GL20.glGetUniformLocation(program, "companionAtlas"), 13);
        GL20.glUniform1i(GL20.glGetUniformLocation(program, "companionRadiance"), 14);
        GL20.glUniform3f(GL20.glGetUniformLocation(program,"companionOrigin"),scene.originX,scene.originY,scene.originZ);
        GL20.glUniform3f(GL20.glGetUniformLocation(program,"companionGiOrigin"),giOriginX,giOriginY,giOriginZ);
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
            return value.replace("#include \"volume.glsl\"",sourceVolume());
        } catch (IOException error) { throw new IllegalStateException(error); }
    }
    private static String sourceVolume() {
        try (var input=GpuLighting.class.getResourceAsStream("/lighting/volume.glsl")) {
            return new String(input.readAllBytes(),StandardCharsets.UTF_8);
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
        for (int texture:new int[] {atlas,depth,voxelTexture,packed[0],packed[1]}) { GL11.glDeleteTextures(texture); }
        for (int program:new int[] {shadowProgram,injectProgram,propagateProgram,accumulateProgram,packProgram}) { GL20.glDeleteProgram(program); }
        GL30.glDeleteFramebuffers(shadowFramebuffer);
        GL30.glDeleteFramebuffers(packedFramebuffer);
        GL30.glDeleteVertexArrays(meshArray);
        GL30.glDeleteVertexArrays(quadArray);
        GL15.glDeleteBuffers(meshBuffer);
    }
}
