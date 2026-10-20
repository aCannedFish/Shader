package local.simpleshader.lighting;

import java.util.Arrays;
import java.util.Comparator;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.tags.BiomeTags;
import net.minecraft.tags.BlockTags;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.phys.Vec3;

/** Coarse outdoor ground data for mist. Reads only loaded client chunks, in a
 * fixed per-frame budget. Overlapping cells survive camera movement; tree crowns
 * are stripped before sampling the ground's biome, sky exposure and block light.
 */
final class TerrainFogCache {
    static final int SIDE = 65;
    static final int SPACING = 4;
    static final float MAGIC = 2718.0f;
    private static final int FOLLOW_STEP = 32;
    private static final int BUDGET = 96;
    private static final int[][] NEIGHBOURS = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}};
    private static final int[] ORDER = makeOrder();
    private final BlockPos.MutableBlockPos position = new BlockPos.MutableBlockPos();
    private float[] cells = new float[SIDE * SIDE * 4];
    private ClientLevel level;
    private int originX;
    private int originZ;
    private int cursor;
    private long revision;
    private long started;

    /** Visit the player's immediate surroundings first, then fill the border. */
    private static int[] makeOrder() {
        Integer[] order = new Integer[SIDE * SIDE];
        Arrays.setAll(order, index -> index);
        int middle = SIDE / 2;
        Arrays.sort(order, Comparator.comparingInt(index -> {
            int x = index % SIDE - middle;
            int z = index / SIDE - middle;
            return x * x + z * z;
        }));
        return Arrays.stream(order).mapToInt(Integer::intValue).toArray();
    }

    /** Rebase the grid in whole cells, preserving every overlapping column. */
    private void move(int x, int z) {
        int dx = (x - originX) / SPACING;
        int dz = (z - originZ) / SPACING;
        float[] previous = cells;
        cells = new float[previous.length];
        for (int row = 0; row < SIDE; row++) {
            for (int column = 0; column < SIDE; column++) {
                int sx = column + dx;
                int sz = row + dz;
                if (sx >= 0 && sz >= 0 && sx < SIDE && sz < SIDE) {
                    System.arraycopy(previous, (sz * SIDE + sx) * 4,
                        cells, (row * SIDE + column) * 4, 4);
                }
            }
        }
        if (Math.abs(dx) >= SIDE || Math.abs(dz) >= SIDE) {
            started = System.nanoTime();
        }
        originX = x;
        originZ = z;
        cursor = 0;
        revision++;
    }

    /** Incrementally refresh native height/light data without forcing chunk loads. */
    void advance(ClientLevel world, Vec3 camera) {
        if (!world.dimension().equals(Level.OVERWORLD)) {
            if (level != null) {
                level = null;
                Arrays.fill(cells, 0.0f);
                revision++;
            }
            originX = Math.floorDiv((int)Math.floor(camera.x), FOLLOW_STEP) * FOLLOW_STEP - SIDE / 2 * SPACING;
            originZ = Math.floorDiv((int)Math.floor(camera.z), FOLLOW_STEP) * FOLLOW_STEP - SIDE / 2 * SPACING;
            return;
        }
        int x = Math.floorDiv((int)Math.floor(camera.x), FOLLOW_STEP) * FOLLOW_STEP - SIDE / 2 * SPACING;
        int z = Math.floorDiv((int)Math.floor(camera.z), FOLLOW_STEP) * FOLLOW_STEP - SIDE / 2 * SPACING;
        if (world != level) {
            level = world;
            Arrays.fill(cells, 0.0f);
            originX = x;
            originZ = z;
            cursor = 0;
            started = System.nanoTime();
            revision++;
        } else if (x != originX || z != originZ) {
            move(x, z);
        }
        for (int work = 0; work < BUDGET; work++) {
            sample(ORDER[cursor]);
            cursor = (cursor + 1) % ORDER.length;
        }
    }

    /** A missing column stays invalid; roofs with no sky exposure cannot seed mist. */
    private void sample(int index) {
        int x = originX + index % SIDE * SPACING;
        int z = originZ + index / SIDE * SPACING;
        LevelChunk chunk = level.getChunkSource().getChunkNow(x >> 4, z >> 4);
        int base = index * 4;
        if (chunk == null) {
            if (cells[base + 3] != 0.0f) {
                cells[base + 3] = 0.0f;
                revision++;
            }
            return;
        }
        int y = chunk.getHeight(Heightmap.Types.WORLD_SURFACE, x & 15, z & 15);
        boolean canopy = false;
        for (int depth = 0; depth < 48 && y > chunk.getMinY(); depth++) {
            BlockState state = level.getBlockState(position.set(x, y, z));
            boolean tree = state.is(BlockTags.LEAVES) || state.is(BlockTags.LOGS);
            canopy |= tree;
            if (!tree && (state.isSolidRender() || !state.getFluidState().isEmpty())) {
                break;
            }
            y--;
        }
        position.set(x, y + 2, z);
        var biome = level.getBiome(position);
        boolean forest = biome.is(BiomeTags.IS_FOREST) || biome.is(BiomeTags.IS_TAIGA)
            || biome.is(BiomeTags.IS_JUNGLE);
        float habitat = forest || canopy ? 1.0f : biome.is(BiomeTags.IS_MOUNTAIN) ? 0.75f : 0.0f;
        int sky = level.getBrightness(LightLayer.SKY, position);
        int block = level.getBrightness(LightLayer.BLOCK, position);
        // A stripped trunk still occupies this column in the light engine.
        // Sample adjacent air rather than treating the forest floor as a cave.
        if (canopy && level.getBlockState(position).isSolidRender()) {
            for (int[] offset : NEIGHBOURS) {
                position.set(x + offset[0], y + 2, z + offset[1]);
                if (level.hasChunkAt(position) && !level.getBlockState(position).isSolidRender()) {
                    sky = Math.max(sky, level.getBrightness(LightLayer.SKY, position));
                    block = Math.max(block, level.getBrightness(LightLayer.BLOCK, position));
                }
            }
        }
        float packedLight = sky * 16 + block;
        if (cells[base] != y + 1 || cells[base + 1] != habitat
            || cells[base + 2] != packedLight || cells[base + 3] != 1.0f) {
            cells[base] = y + 1;
            cells[base + 1] = habitat;
            cells[base + 2] = packedLight;
            cells[base + 3] = 1.0f;
            revision++;
        }
    }

    float[] cells() {
        return cells;
    }

    long revision() {
        return revision;
    }

    int originX() {
        return originX;
    }

    int originZ() {
        return originZ;
    }

    float fade() {
        return level == null ? 0.0f : Math.min((System.nanoTime() - started) / 1_500_000_000.0f, 1.0f);
    }
}
