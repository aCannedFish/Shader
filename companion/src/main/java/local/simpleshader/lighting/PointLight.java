package local.simpleshader.lighting;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;
import net.minecraft.world.phys.AABB;

/** A shadow-casting emitter anchored to its own block. Its occluders are gathered
 * around the light itself, so its shadows do not depend on where the camera-centred
 * radiance volume is. x/y/z are absolute block coordinates; offset is the position
 * of the light inside that block.
 */
record PointLight(int x, int y, int z, float offsetX, float offsetY, float offsetZ, float radius,
                  float r, float g, float b, int emission, BlockState state) {
    /** Opaque and glass triangles relative to the light's block corner. */
    record Mesh(float[] opaque, float[] glass, long stateHash) {
        int hash() {
            return 31 * Arrays.hashCode(opaque) + Arrays.hashCode(glass);
        }
    }

    private static final long HASH_START = 0xcbf29ce484222325L;

    /** Interned block states include orientation, slab shape and glass connections.
     * Unloaded cells and air both cast nothing, matching the mesh gather rules.
     */
    private static long hashState(long hash, BlockState state) {
        int value = state == null || state.isAir() ? 0 : System.identityHashCode(state);
        return (hash ^ value) * 0x100000001b3L;
    }

    /** Cheap, resumable validation of a mapped light. Unchanged scenes do not
     * allocate boxes, query shapes or construct another pair of vertex arrays.
     */
    static final class StateScan {
        final PointLight light;
        private final int half;
        private final int side;
        private final double reach;
        private int cursor;
        private boolean loaded;
        private LevelChunk chunk;
        private LevelChunkSection section;
        private int sectionIndex = Integer.MIN_VALUE;
        private long hash = HASH_START;

        StateScan(PointLight light) {
            this.light = light;
            half = (int) Math.ceil(light.radius) + 1;
            side = half * 2 + 1;
            reach = (light.radius + 1.0) * (light.radius + 1.0);
        }

        boolean advance(ClientLevel level, long deadline) {
            int cells = side * side * side;
            // A chunk may unload between two slices of this scan.
            if (cursor < cells && cursor % side != 0) {
                int cx = (cursor / side) % side - half;
                int cz = cursor / (side * side) - half;
                chunk = level.getChunkSource().getChunkNow((light.x + cx) >> 4, (light.z + cz) >> 4);
                loaded = chunk != null;
                sectionIndex = Integer.MIN_VALUE;
            }
            for (; cursor < cells; cursor++) {
                if ((cursor & 127) == 0 && System.nanoTime() >= deadline) {
                    return false;
                }
                int cy = cursor % side - half;
                int cx = (cursor / side) % side - half;
                int cz = cursor / (side * side) - half;
                if (cursor % side == 0) {
                    chunk = level.getChunkSource().getChunkNow((light.x + cx) >> 4, (light.z + cz) >> 4);
                    loaded = chunk != null;
                    sectionIndex = Integer.MIN_VALUE;
                }
                double dx = cx + 0.5 - light.offsetX;
                double dy = cy + 0.5 - light.offsetY;
                double dz = cz + 0.5 - light.offsetZ;
                if (dx * dx + dy * dy + dz * dz > reach || cx == 0 && cy == 0 && cz == 0) {
                    continue;
                }
                BlockState state = null;
                if (loaded) {
                    int worldY = light.y + cy;
                    int index = chunk.getSectionIndex(worldY);
                    if (index != sectionIndex) {
                        sectionIndex = index;
                        LevelChunkSection[] sections = chunk.getSections();
                        section = index >= 0 && index < sections.length ? sections[index] : null;
                    }
                    if (section != null) {
                        state = section.getBlockState((light.x + cx) & 15, worldY & 15, (light.z + cz) & 15);
                    }
                }
                hash = hashState(hash, state);
            }
            return true;
        }

        long hash() {
            return hash;
        }
    }

    /** The shader's warm vanilla block-light tint, linear, used when coloured lighting is off. */
    private static final float[] NATIVE_TINT = {1.0f, (float) Math.pow(0.65, 2.2), (float) Math.pow(0.32, 2.2)};

    static float radius(int emission, ShaderSettings settings) {
        return settings.radius * Math.max(emission / 15.0f, 0.25f);
    }

    static PointLight of(ColourSources.Source source, ShaderSettings settings) {
        BlockState state = source.state();
        float px = 0.5f;
        float pz = 0.5f;
        if (state.is(Blocks.WALL_TORCH) || state.is(Blocks.SOUL_WALL_TORCH)
            || state.is(Blocks.REDSTONE_WALL_TORCH)) {
            Direction facing = state.getValue(BlockStateProperties.HORIZONTAL_FACING);
            px += facing.getStepX() * 0.20f;
            pz += facing.getStepZ() * 0.20f;
        }
        float[] colour = settings.coloured ? new float[] {source.r(), source.g(), source.b()} : NATIVE_TINT;
        // Hue is already linear; keep the existing emission-level energy calibration.
        float energy = 2.0f * source.emission() / 15.0f;
        return new PointLight(source.x(), source.y(), source.z(), px, 0.72f, pz,
            radius(source.emission(), settings), colour[0] * energy, colour[1] * energy, colour[2] * energy,
            source.emission(), state);
    }

    /** Same emitter and reach, so an existing shadow map stays valid. */
    boolean sameMap(PointLight other) {
        return x == other.x && y == other.y && z == other.z && state == other.state && radius == other.radius;
    }

    /** Whether any occluder this light's map depends on can lie in the world box [min, max]. */
    boolean reaches(double minX, double minY, double minZ, double maxX, double maxY, double maxZ) {
        double px = x + offsetX;
        double py = y + offsetY;
        double pz = z + offsetZ;
        double dx = Math.max(Math.max(minX - px, px - maxX), 0.0);
        double dy = Math.max(Math.max(minY - py, py - maxY), 0.0);
        double dz = Math.max(Math.max(minZ - pz, pz - maxZ), 0.0);
        return dx * dx + dy * dy + dz * dz <= (radius + 1.0) * (radius + 1.0);
    }

    /** Occluders within reach, with the same rules as the radiance-volume scan.
     * The emitter's own cell is skipped so the light is not hidden by its block.
     */
    Mesh gather(ClientLevel level) {
        int half = (int) Math.ceil(radius) + 1;
        int side = half * 2 + 1;
        boolean[] fullCells = new boolean[side * side * side];
        List<SceneVolume.Box> boxes = new ArrayList<>();
        List<SceneVolume.Box> glass = new ArrayList<>();
        BlockPos.MutableBlockPos position = new BlockPos.MutableBlockPos();
        double reach = (radius + 1.0) * (radius + 1.0);
        long stateHash = HASH_START;
        for (int lz = 0; lz < side; lz++) {
            for (int lx = 0; lx < side; lx++) {
                int cx = lx - half;
                int cz = lz - half;
                // Unloaded columns cast nothing; the periodic refresh redraws the map later.
                boolean loaded = level.hasChunk((x + cx) >> 4, (z + cz) >> 4);
                for (int ly = 0; ly < side; ly++) {
                    int cy = ly - half;
                    double dx = cx + 0.5 - offsetX;
                    double dy = cy + 0.5 - offsetY;
                    double dz = cz + 0.5 - offsetZ;
                    if (dx * dx + dy * dy + dz * dz > reach || cx == 0 && cy == 0 && cz == 0) {
                        continue;
                    }
                    if (!loaded) {
                        stateHash = hashState(stateHash, null);
                        continue;
                    }
                    position.set(x + cx, y + cy, z + cz);
                    BlockState cell = level.getBlockState(position);
                    stateHash = hashState(stateHash, cell);
                    if (cell.isAir()) {
                        continue;
                    }
                    int index = (lz * side + ly) * side + lx;
                    if (LightMaterials.absorption(cell) != null) {
                        for (AABB shape : cell.getShape(level, position).toAabbs()) {
                            glass.add(new SceneVolume.Box(shape.move(cx, cy, cz), index, false));
                        }
                    }
                    if (cell.getLightBlock() == 0) {
                        continue;
                    }
                    boolean full = cell.isCollisionShapeFullBlock(level, position);
                    fullCells[index] = full;
                    List<AABB> shapes = full ? List.of(new AABB(0, 0, 0, 1, 1, 1))
                        : cell.getShape(level, position).toAabbs();
                    for (AABB shape : shapes) {
                        boxes.add(new SceneVolume.Box(shape.move(cx, cy, cz), index, full));
                    }
                }
            }
        }
        return new Mesh(SceneVolume.mesh(boxes, side, fullCells), SceneVolume.mesh(glass, side, fullCells), stateHash);
    }
}
