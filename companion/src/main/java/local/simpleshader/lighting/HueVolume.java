package local.simpleshader.lighting;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.SectionPos;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.level.chunk.PalettedContainer;
import net.minecraft.world.level.lighting.LightEngine;
import net.minecraft.world.phys.Vec3;

/** Emitter hue propagated with vanilla block-light rules. One flood per emitter
 * colour reproduces the native maximum propagation, walls and slabs included, so
 * a hue only reaches cells its own emitters actually light. Each cell stores the
 * radiance-weighted mean hue and emission level; the shader derives the energy
 * from the native level and that emission, so weaker emitters keep a visible
 * near field over their own shorter range.
 * The client thread only copies section palettes; floods run on a worker.
 * Single-hue bricks live in the indirection texel itself. Mixed bricks keep
 * stable pool slots keyed by world position, so only changed bricks upload.
 * Layout must match companion_lighting.glsl (COMPANION_HUE_*).
 */
final class HueVolume implements AutoCloseable {
    static final int BRICK = 8;
    static final int BRICKS_X = 32;
    static final int BRICKS_Y = 16;
    static final int BRICKS_Z = 32;
    static final int BRICKS = BRICKS_X * BRICKS_Y * BRICKS_Z;
    static final int POOL = 2048;
    static final int TEXELS = BRICK * BRICK * BRICK;
    private static final int SNAP_XZ = 32;
    private static final int SNAP_Y = 16;
    /** Farthest region edge from the camera for any snapped origin. */
    static final int HORIZONTAL_REACH = BRICKS_X * BRICK / 2 + SNAP_XZ;
    static final int VERTICAL_REACH = BRICKS_Y * BRICK / 2 + SNAP_Y;
    private static final int SIZE_X = BRICKS_X * BRICK;
    private static final int SIZE_Y = BRICKS_Y * BRICK;
    private static final int SIZE_Z = BRICKS_Z * BRICK;
    /** Opacity in the low four bits, fully occluded faces above (Direction order). */
    private static final short BLOCKED = 15;
    private static final int[] DX = {0, 0, 0, 0, -1, 1};
    private static final int[] DY = {-1, 1, 0, 0, 0, 0};
    private static final int[] DZ = {0, 0, -1, 1, 0, 0};
    /** Per emission level and propagated level; the cell's share of radiance. */
    private static final float[][] WEIGHT = new float[16][16];
    /** Per-cell sums: weighted r, g, b, weight and weighted emission. */
    private static final int SUM = 5;
    /** Unseen block edits (doors, pistons) are picked up by a periodic re-copy. */
    private static final long REFRESH = 10_000_000_000L;

    static {
        // The shader's emitter attenuation at the default falloff: hues mix in
        // proportion to the radiance each emitter group delivers.
        for (int emission = 1; emission < 16; emission++) {
            for (int level = 1; level <= emission; level++) {
                float distance = 1.0f - (float) level / emission;
                float squared = distance * distance;
                float cutoff = 1.0f - squared * squared;
                float blocks = 2.0f + distance * emission;
                WEIGHT[emission][level] = emission / 15.0f * cutoff * cutoff / (1.0f + blocks * blocks);
            }
        }
    }

    /** Indirection texels are (0,0,0,0) unlit, (hue,-emission) single-hue, (slot,0,0,1) pooled.
     * Pooled texels are (hue, emission), zero where unlit. */
    record Result(int originX, int originY, int originZ, float[] indirection, int[] slots, float[][] bricks,
                  long millis) {}
    private record Job(List<ColourSources.Source> sources, int x, int y, int z, double cameraX, double cameraY,
                       double cameraZ, Map<Long, PalettedContainer<BlockState>> sections, Set<Long> invalidated,
                       boolean reset) {}
    private record Group(float r, float g, float b, int emission) {}

    // Client thread.
    private final ExecutorService worker = Executors.newSingleThreadExecutor(task -> {
        Thread thread = new Thread(task, "SimpleShader coloured light");
        thread.setDaemon(true);
        return thread;
    });
    private final Map<Long, PalettedContainer<BlockState>> copies = new HashMap<>();
    private final Set<Long> invalidated = new HashSet<>();
    private Future<Result> running;
    private ClientLevel level;
    private List<ColourSources.Source> requested;
    private int requestX;
    private int requestY;
    private int requestZ;
    private boolean stale = true;
    private boolean reset = true;
    private long nextRefresh;

    // Worker thread.
    private final Map<Long, Integer> slots = new HashMap<>();
    private final float[][] pool = new float[POOL][];
    private final Map<Long, short[]> occlusion = new HashMap<>();
    private final Map<BlockState, Short> described = new IdentityHashMap<>();
    private final short[][] cells = new short[BRICKS][];
    private final byte[][] levels = new byte[BRICKS][];
    private final float[][] sums = new float[BRICKS][];
    private final int[] touched = new int[BRICKS];
    private final boolean[] raised = new boolean[BRICKS];
    private final int[] lit = new int[BRICKS];
    private final boolean[] listed = new boolean[BRICKS];
    private final int[][] buckets = new int[16][];
    private final int[] bucketSize = new int[16];
    private final float[] content = new float[TEXELS * 4];
    private int touchedCount;
    private int litCount;
    private Job job;
    private int originX;
    private int originY;
    private int originZ;

    HueVolume() {
        for (int index = 0; index < buckets.length; index++) {
            buckets[index] = new int[256];
        }
    }

    static int originX(double camera) { return origin(camera, SNAP_XZ, SIZE_X); }
    static int originY(double camera) { return origin(camera, SNAP_Y, SIZE_Y); }
    static int originZ(double camera) { return origin(camera, SNAP_XZ, SIZE_Z); }

    private static int origin(double camera, int snap, int size) {
        return Math.floorDiv((int) Math.floor(camera), snap) * snap - size / 2;
    }

    /** A changed section may open or close light paths. */
    void invalidate(long section) {
        copies.remove(section);
        invalidated.add(section);
        stale = true;
    }

    /** Request a rebuild even if sources and origin are unchanged. */
    void invalidateAll() {
        stale = true;
    }

    /** Return a finished flood, if any, and start the next one when inputs changed. */
    Result poll(ClientLevel world, List<ColourSources.Source> sources, Vec3 camera) {
        Result done = null;
        if (running != null && running.isDone()) {
            try {
                done = running.get();
            } catch (InterruptedException | ExecutionException error) {
                throw new IllegalStateException("Coloured light flood failed", error);
            } finally {
                running = null;
            }
        }
        long now = System.nanoTime();
        if (world != level || now >= nextRefresh) {
            level = world;
            copies.clear();
            invalidated.clear();
            reset = true;
            stale = true;
            nextRefresh = now + REFRESH;
        }
        int x = originX(camera.x);
        int y = originY(camera.y);
        int z = originZ(camera.z);
        if (running == null && (stale || sources != requested || x != requestX || y != requestY || z != requestZ)) {
            Job next = new Job(sources, x, y, z, camera.x, camera.y, camera.z, snapshot(world, sources, x, y, z),
                Set.copyOf(invalidated), reset);
            running = worker.submit(() -> build(next));
            requested = sources;
            requestX = x;
            requestY = y;
            requestZ = z;
            stale = false;
            reset = false;
            invalidated.clear();
        }
        return done;
    }

    /** Copy every loaded section an emitter's light can reach inside the region. */
    private Map<Long, PalettedContainer<BlockState>> snapshot(ClientLevel world, List<ColourSources.Source> sources,
                                                              int x, int y, int z) {
        int sectionsX = SIZE_X / 16 + 1;
        int sectionsY = SIZE_Y / 16 + 1;
        int sectionsZ = SIZE_Z / 16 + 1;
        int baseX = x >> 4;
        int baseY = y >> 4;
        int baseZ = z >> 4;
        boolean[] needed = new boolean[sectionsX * sectionsY * sectionsZ];
        for (ColourSources.Source source : sources) {
            int reach = source.emission() - 1;
            int minX = Math.max(source.x() - reach, x) >> 4;
            int maxX = Math.min(source.x() + reach, x + SIZE_X - 1) >> 4;
            int minY = Math.max(source.y() - reach, y) >> 4;
            int maxY = Math.min(source.y() + reach, y + SIZE_Y - 1) >> 4;
            int minZ = Math.max(source.z() - reach, z) >> 4;
            int maxZ = Math.min(source.z() + reach, z + SIZE_Z - 1) >> 4;
            for (int sy = minY; sy <= maxY; sy++) {
                for (int sz = minZ; sz <= maxZ; sz++) {
                    for (int sx = minX; sx <= maxX; sx++) {
                        needed[((sy - baseY) * sectionsZ + sz - baseZ) * sectionsX + sx - baseX] = true;
                    }
                }
            }
        }
        Map<Long, PalettedContainer<BlockState>> result = new HashMap<>();
        for (int index = 0; index < needed.length; index++) {
            if (!needed[index]) {
                continue;
            }
            int sx = baseX + index % sectionsX;
            int sz = baseZ + (index / sectionsX) % sectionsZ;
            int sy = baseY + index / (sectionsX * sectionsZ);
            long key = SectionPos.asLong(sx, sy, sz);
            PalettedContainer<BlockState> copy = copies.get(key);
            if (copy == null) {
                LevelChunk chunk = world.getChunkSource().getChunkNow(sx, sz);
                int section = chunk == null ? -1 : chunk.getSectionIndexFromSectionY(sy);
                LevelChunkSection[] available = chunk == null ? null : chunk.getSections();
                if (available == null || section < 0 || section >= available.length) {
                    // Unloaded or outside the world: blocks light and is retried later.
                    continue;
                }
                copy = available[section].getStates().copy();
                copies.put(key, copy);
            }
            result.put(key, copy);
        }
        copies.keySet().retainAll(result.keySet());
        return result;
    }

    // ---- Worker thread ----

    private Result build(Job value) {
        long start = System.nanoTime();
        job = value;
        if (value.reset) {
            occlusion.clear();
        }
        for (long section : value.invalidated) {
            int x = SectionPos.x(section) * 2;
            int y = SectionPos.y(section) * 2;
            int z = SectionPos.z(section) * 2;
            for (int index = 0; index < 8; index++) {
                occlusion.remove(BlockPos.asLong(x + (index & 1), y + ((index >> 1) & 1), z + (index >> 2)));
            }
        }
        if (value.x != originX || value.y != originY || value.z != originZ) {
            originX = value.x;
            originY = value.y;
            originZ = value.z;
            int minX = originX >> 3;
            int minY = originY >> 3;
            int minZ = originZ >> 3;
            occlusion.keySet().removeIf(key -> {
                int bx = BlockPos.getX(key) - minX;
                int by = BlockPos.getY(key) - minY;
                int bz = BlockPos.getZ(key) - minZ;
                return bx < 0 || by < 0 || bz < 0 || bx >= BRICKS_X || by >= BRICKS_Y || bz >= BRICKS_Z;
            });
        }
        Arrays.fill(cells, null);
        Map<Group, List<ColourSources.Source>> groups = new HashMap<>();
        for (ColourSources.Source source : value.sources) {
            groups.computeIfAbsent(new Group(source.r(), source.g(), source.b(), source.emission()),
                key -> new ArrayList<>()).add(source);
        }
        for (Map.Entry<Group, List<ColourSources.Source>> group : groups.entrySet()) {
            flood(group.getValue(), group.getKey());
        }
        Result result = publish(value.cameraX, value.cameraY, value.cameraZ, start);
        job = null;
        return result;
    }

    private void flood(List<ColourSources.Source> sources, Group colour) {
        for (ColourSources.Source source : sources) {
            int x = source.x() - originX;
            int y = source.y() - originY;
            int z = source.z() - originZ;
            if (inside(x, y, z) && raise(x, y, z, source.emission())) {
                push(source.emission(), pack(x, y, z));
            }
        }
        // Levels only fall, so draining buckets from the top settles each cell once.
        for (int value = 15; value > 1; value--) {
            for (int item = 0; item < bucketSize[value]; item++) {
                int cell = buckets[value][item];
                int x = cell & 255;
                int y = (cell >> 8) & 255;
                int z = cell >>> 16;
                if (level(x, y, z) != value) {
                    continue;
                }
                int from = occlusion(x, y, z);
                for (int face = 0; face < 6; face++) {
                    int nx = x + DX[face];
                    int ny = y + DY[face];
                    int nz = z + DZ[face];
                    if (!inside(nx, ny, nz) || (from & (16 << face)) != 0) {
                        continue;
                    }
                    int to = occlusion(nx, ny, nz);
                    int next = value - (to & 15);
                    if (next > 0 && (to & (16 << (face ^ 1))) == 0 && raise(nx, ny, nz, next)) {
                        push(next, pack(nx, ny, nz));
                    }
                }
            }
            bucketSize[value] = 0;
        }
        bucketSize[1] = 0;
        for (int index = 0; index < touchedCount; index++) {
            int brick = touched[index];
            byte[] values = levels[brick];
            float[] sum = sums[brick];
            if (sum == null) {
                sum = sums[brick] = new float[TEXELS * SUM];
            }
            for (int cell = 0; cell < TEXELS; cell++) {
                if (values[cell] > 0) {
                    float weight = WEIGHT[colour.emission][values[cell]];
                    sum[cell * SUM] += weight * colour.r;
                    sum[cell * SUM + 1] += weight * colour.g;
                    sum[cell * SUM + 2] += weight * colour.b;
                    sum[cell * SUM + 3] += weight;
                    sum[cell * SUM + 4] += weight * colour.emission;
                }
            }
            if (!listed[brick]) {
                listed[brick] = true;
                lit[litCount++] = brick;
            }
            Arrays.fill(values, (byte) 0);
            raised[brick] = false;
        }
        touchedCount = 0;
    }

    /** Keep slots stable by world brick, then report pooled bricks whose texels changed. */
    private Result publish(double cameraX, double cameraY, double cameraZ, long start) {
        float[] indirection = new float[BRICKS * 4];
        List<Integer> mixed = new ArrayList<>();
        for (int index = 0; index < litCount; index++) {
            int brick = lit[index];
            float[] sum = sums[brick];
            float r = -1.0f;
            float g = 0.0f;
            float b = 0.0f;
            float e = 0.0f;
            boolean uniform = true;
            for (int cell = 0; cell < TEXELS && uniform; cell++) {
                float weight = sum[cell * SUM + 3];
                if (weight <= 0.0f) {
                    continue;
                }
                float cr = sum[cell * SUM] / weight;
                float cg = sum[cell * SUM + 1] / weight;
                float cb = sum[cell * SUM + 2] / weight;
                float ce = sum[cell * SUM + 4] / weight;
                if (r < 0.0f) {
                    r = cr;
                    g = cg;
                    b = cb;
                    e = ce;
                } else {
                    uniform = Math.abs(cr - r) + Math.abs(cg - g) + Math.abs(cb - b) < 0.002f
                        && Math.abs(ce - e) < 0.05f;
                }
            }
            if (uniform) {
                indirection[brick * 4] = r;
                indirection[brick * 4 + 1] = g;
                indirection[brick * 4 + 2] = b;
                indirection[brick * 4 + 3] = -e;
            } else {
                mixed.add(brick);
            }
        }
        if (mixed.size() > POOL) {
            // Overflowing mixed bricks fall back to the native tint, farthest first.
            mixed.sort((a, b) -> Double.compare(brickDistance(a, cameraX, cameraY, cameraZ),
                brickDistance(b, cameraX, cameraY, cameraZ)));
            CompanionMod.LOGGER.warn("SIMPLE_LIGHTING coloured light pool full: {} mixed bricks", mixed.size());
            mixed = mixed.subList(0, POOL);
        }
        Map<Long, Integer> retained = new HashMap<>();
        boolean[] used = new boolean[POOL];
        long[] keys = new long[mixed.size()];
        for (int index = 0; index < keys.length; index++) {
            keys[index] = worldBrick(mixed.get(index));
            Integer slot = slots.get(keys[index]);
            if (slot != null) {
                retained.put(keys[index], slot);
                used[slot] = true;
            }
        }
        List<Integer> dirty = new ArrayList<>();
        List<float[]> data = new ArrayList<>();
        int free = 0;
        for (int index = 0; index < keys.length; index++) {
            Integer slot = retained.get(keys[index]);
            if (slot == null) {
                while (used[free]) {
                    free++;
                }
                slot = free;
                used[slot] = true;
                retained.put(keys[index], slot);
            }
            int brick = mixed.get(index);
            indirection[brick * 4] = slot;
            indirection[brick * 4 + 3] = 1.0f;
            float[] sum = sums[brick];
            for (int cell = 0; cell < TEXELS; cell++) {
                int offset = cell * 4;
                float weight = sum[cell * SUM + 3];
                if (weight > 0.0f) {
                    content[offset] = sum[cell * SUM] / weight;
                    content[offset + 1] = sum[cell * SUM + 1] / weight;
                    content[offset + 2] = sum[cell * SUM + 2] / weight;
                    content[offset + 3] = sum[cell * SUM + 4] / weight;
                } else {
                    content[offset] = content[offset + 1] = content[offset + 2] = content[offset + 3] = 0.0f;
                }
            }
            if (pool[slot] == null || !Arrays.equals(pool[slot], content)) {
                pool[slot] = content.clone();
                dirty.add(slot);
                data.add(pool[slot]);
            }
        }
        slots.clear();
        slots.putAll(retained);
        for (int index = 0; index < litCount; index++) {
            Arrays.fill(sums[lit[index]], 0.0f);
            listed[lit[index]] = false;
        }
        litCount = 0;
        return new Result(originX, originY, originZ, indirection, dirty.stream().mapToInt(Integer::intValue).toArray(),
            data.toArray(new float[0][]), (System.nanoTime() - start) / 1_000_000L);
    }

    private double brickDistance(int brick, double cameraX, double cameraY, double cameraZ) {
        double dx = originX + (brick % BRICKS_X) * BRICK + 4 - cameraX;
        double dy = originY + (brick / (BRICKS_X * BRICKS_Z)) * BRICK + 4 - cameraY;
        double dz = originZ + ((brick / BRICKS_X) % BRICKS_Z) * BRICK + 4 - cameraZ;
        return dx * dx + dy * dy + dz * dz;
    }

    private long worldBrick(int brick) {
        return BlockPos.asLong((originX >> 3) + brick % BRICKS_X,
            (originY >> 3) + brick / (BRICKS_X * BRICKS_Z), (originZ >> 3) + (brick / BRICKS_X) % BRICKS_Z);
    }

    private static boolean inside(int x, int y, int z) {
        return x >= 0 && y >= 0 && z >= 0 && x < SIZE_X && y < SIZE_Y && z < SIZE_Z;
    }

    private static int pack(int x, int y, int z) {
        return x | (y << 8) | (z << 16);
    }

    private static int brick(int x, int y, int z) {
        return ((y >> 3) * BRICKS_Z + (z >> 3)) * BRICKS_X + (x >> 3);
    }

    private static int cell(int x, int y, int z) {
        return ((z & 7) * BRICK + (y & 7)) * BRICK + (x & 7);
    }

    private int level(int x, int y, int z) {
        byte[] values = levels[brick(x, y, z)];
        return values == null ? 0 : values[cell(x, y, z)];
    }

    private boolean raise(int x, int y, int z, int value) {
        int brick = brick(x, y, z);
        byte[] values = levels[brick];
        if (values == null) {
            values = levels[brick] = new byte[TEXELS];
        }
        int cell = cell(x, y, z);
        if (values[cell] >= value) {
            return false;
        }
        if (!raised[brick]) {
            raised[brick] = true;
            touched[touchedCount++] = brick;
        }
        values[cell] = (byte) value;
        return true;
    }

    private void push(int value, int cell) {
        if (bucketSize[value] == buckets[value].length) {
            buckets[value] = Arrays.copyOf(buckets[value], buckets[value].length * 2);
        }
        buckets[value][bucketSize[value]++] = cell;
    }

    private int occlusion(int x, int y, int z) {
        int brick = brick(x, y, z);
        short[] data = cells[brick];
        if (data == null) {
            data = cells[brick] = load(brick);
        }
        return data[cell(x, y, z)];
    }

    /** Sections missing from the snapshot block light and are not cached. */
    private short[] load(int brick) {
        long key = worldBrick(brick);
        short[] cached = occlusion.get(key);
        if (cached != null) {
            return cached;
        }
        int x = BlockPos.getX(key) * BRICK;
        int y = BlockPos.getY(key) * BRICK;
        int z = BlockPos.getZ(key) * BRICK;
        short[] data = new short[TEXELS];
        PalettedContainer<BlockState> section = job.sections.get(SectionPos.asLong(x >> 4, y >> 4, z >> 4));
        if (section == null) {
            Arrays.fill(data, BLOCKED);
            return data;
        }
        for (int cell = 0; cell < TEXELS; cell++) {
            BlockState state = section.get((x & 15) + (cell & 7), (y & 15) + ((cell >> 3) & 7), (z & 15) + (cell >> 6));
            data[cell] = described.computeIfAbsent(state, HueVolume::describe);
        }
        occlusion.put(key, data);
        return data;
    }

    /** Vanilla opacity (at least one level per step) and shape-occluded faces. */
    private static short describe(BlockState state) {
        int value = Math.min(15, Math.max(1, state.getLightBlock()));
        for (Direction direction : Direction.values()) {
            if (Block.isFaceFull(LightEngine.getOcclusionShape(state, direction), direction)) {
                value |= 16 << direction.ordinal();
            }
        }
        return (short) value;
    }

    @Override
    public void close() {
        worker.shutdownNow();
    }
}
