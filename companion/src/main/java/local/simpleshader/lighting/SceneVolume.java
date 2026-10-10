package local.simpleshader.lighting;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;

/** Immutable scene snapshot built incrementally on the client thread. */
final class SceneVolume {
    record Light(float x, float y, float z, float radius, float r, float g, float b, int owner) {}
    record Box(AABB bounds, int owner, boolean full) {}

    final int size;
    final int originX;
    final int originY;
    final int originZ;
    final float[] voxels;
    private final boolean[] fullCells;
    final List<Light> lights = new ArrayList<>();
    final List<Box> boxes = new ArrayList<>();
    private final ClientLevel level;
    private final ShaderSettings settings;
    private final Vec3 camera;
    private int cursor;

    SceneVolume(ClientLevel level, Vec3 camera, ShaderSettings settings) {
        this.level = level;
        this.camera = camera;
        this.settings = settings;
        size = settings.size;
        originX = (int) Math.floor(camera.x / 4.0) * 4 - size / 2;
        originY = (int) Math.floor(camera.y / 4.0) * 4 - size / 2;
        originZ = (int) Math.floor(camera.z / 4.0) * 4 - size / 2;
        voxels = new float[size * size * size * 4];
        fullCells = new boolean[size * size * size];
    }

    boolean advance(int budget) {
        BlockPos.MutableBlockPos position = new BlockPos.MutableBlockPos();
        int end = Math.min(cursor + budget, size * size * size);
        for (; cursor < end; cursor++) {
            int x = cursor % size;
            int y = (cursor / size) % size;
            int z = cursor / (size * size);
            position.set(originX + x, originY + y, originZ + z);
            int offset = cursor * 4;
            if (!level.hasChunk(position.getX() >> 4, position.getZ() >> 4)) {
                // Unloaded cells block propagation instead of creating light leaks.
                voxels[offset + 3] = 1.0f;
                continue;
            }
            BlockState state = level.getBlockState(position);
            int sky = level.getBrightness(LightLayer.SKY, position);
            voxels[offset + 3] = sky / 32.0f;
            int emission = state.getLightEmission();
            if (emission > 0) {
                collectLight(state, x, y, z, emission, cursor);
            }
            if (state.isAir() || state.getLightBlock() == 0) {
                continue;
            }
            int color = state.getMapColor(level, position).col;
            voxels[offset] = linear((color >> 16) & 255);
            voxels[offset + 1] = linear((color >> 8) & 255);
            voxels[offset + 2] = linear(color & 255);
            boolean full = state.isCollisionShapeFullBlock(level, position);
            fullCells[cursor] = full;
            List<AABB> shapes = full ? List.of(new AABB(0, 0, 0, 1, 1, 1))
                : state.getShape(level, position).toAabbs();
            double occupied = 0.0;
            for (AABB shape : shapes) {
                occupied += shape.getXsize() * shape.getYsize() * shape.getZsize();
                boxes.add(new Box(shape.move(x, y, z), cursor, full));
            }
            if (occupied >= 0.20) {
                voxels[offset + 3] += 1.0f;
            }
        }
        if (cursor < size * size * size) {
            return false;
        }
        lights.sort(Comparator.comparingDouble(light -> {
            double dx = originX + light.x - camera.x;
            double dy = originY + light.y - camera.y;
            double dz = originZ + light.z - camera.z;
            return (dx * dx + dy * dy + dz * dz) / Math.max(light.radius, 1.0f);
        }));
        if (lights.size() > settings.lightLimit) {
            lights.subList(settings.lightLimit, lights.size()).clear();
        }
        return true;
    }

    private void collectLight(BlockState state, int x, int y, int z, int emission, int owner) {
        float px = x + 0.5f;
        float py = y + 0.72f;
        float pz = z + 0.5f;
        float red = 1.0f;
        float green = 0.65f;
        float blue = 0.32f;
        if (state.is(Blocks.WALL_TORCH) || state.is(Blocks.SOUL_WALL_TORCH)
            || state.is(Blocks.REDSTONE_WALL_TORCH)) {
            Direction facing = state.getValue(BlockStateProperties.HORIZONTAL_FACING);
            px += facing.getStepX() * 0.20f;
            pz += facing.getStepZ() * 0.20f;
        }
        if (state.is(Blocks.SEA_LANTERN) || state.is(Blocks.SOUL_TORCH)
            || state.is(Blocks.SOUL_WALL_TORCH) || state.is(Blocks.SOUL_LANTERN)) {
            red = 0.45f;
            green = 0.80f;
            blue = 1.0f;
        } else if (state.is(Blocks.REDSTONE_TORCH) || state.is(Blocks.REDSTONE_WALL_TORCH)) {
            green = 0.08f;
            blue = 0.02f;
        }
        float radius = settings.radius * Math.max(emission / 15.0f, 0.25f);
        float energy = 6.0f * emission / 15.0f;
        lights.add(new Light(px, py, pz, radius, red * energy, green * energy, blue * energy, owner));
    }

    /** Cull internal full-cube faces while preserving slab, stair and fence boxes. */
    float[] mesh() {
        List<Float> vertices = new ArrayList<>();
        int[][] neighbours = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
        int[][] faces = {{1,3,7,5},{0,4,6,2},{2,6,7,3},{0,1,5,4},{4,5,7,6},{0,2,3,1}};
        int[] order = {0,1,2,0,2,3};
        for (Box box : boxes) {
            AABB b = box.bounds;
            float[][] corners = new float[8][3];
            for (int index = 0; index < 8; index++) {
                corners[index] = new float[] {(float)((index & 1) == 0 ? b.minX : b.maxX),
                    (float)((index & 2) == 0 ? b.minY : b.maxY),
                    (float)((index & 4) == 0 ? b.minZ : b.maxZ)};
            }
            int cx = box.owner % size;
            int cy = (box.owner / size) % size;
            int cz = box.owner / (size * size);
            for (int face = 0; face < 6; face++) {
                int nx = cx + neighbours[face][0];
                int ny = cy + neighbours[face][1];
                int nz = cz + neighbours[face][2];
                if (box.full && nx >= 0 && ny >= 0 && nz >= 0 && nx < size && ny < size && nz < size
                    && fullCells[(nz * size + ny) * size + nx]) {
                    continue;
                }
                for (int corner : order) {
                    float[] point = corners[faces[face][corner]];
                    vertices.add(point[0]);
                    vertices.add(point[1]);
                    vertices.add(point[2]);
                    vertices.add((float)box.owner);
                }
            }
        }
        float[] result = new float[vertices.size()];
        for (int index = 0; index < result.length; index++) {
            result[index] = vertices.get(index);
        }
        return result;
    }

    private static float linear(int channel) {
        return (float)Math.pow(channel / 255.0, 2.2);
    }
}
