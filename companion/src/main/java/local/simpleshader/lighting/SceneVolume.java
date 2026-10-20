package local.simpleshader.lighting;

import java.util.ArrayList;
import java.util.List;
import java.util.Arrays;

import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;

/** Immutable scene snapshot built incrementally on the client thread. Point
 * lights are not collected here: each gathers its own geometry (PointLight).
 */
final class SceneVolume {
    record Box(AABB bounds, int owner, boolean full) {}

    /** Map colours are bytes; preserve the original conversion exactly once per value. */
    private static final float[] LINEAR = new float[256];
    static {
        for (int channel = 0; channel < LINEAR.length; channel++) {
            LINEAR[channel] = (float) Math.pow(channel / 255.0, 2.2);
        }
    }

    final int size;
    final int originX;
    final int originY;
    final int originZ;
    final float[] voxels;
    final float[] absorption;
    /** States contributing shadow geometry (boxes or glass), null elsewhere. */
    final BlockState[] occluders;
    int transmittingCells;
    private final boolean[] fullCells;
    private final List<Box> partialBoxes = new ArrayList<>();
    private int fullCellCount;
    private final List<Box> glassBoxes = new ArrayList<>();
    private final ClientLevel level;
    private final ShaderSettings settings;
    private int cursor;

    SceneVolume(ClientLevel level, Vec3 camera, ShaderSettings settings) {
        this.level = level;
        this.settings = settings;
        size = settings.size;
        originX = origin(camera.x, size);
        originY = origin(camera.y, size);
        originZ = origin(camera.z, size);
        voxels = new float[size * size * size * 4];
        occluders = new BlockState[size * size * size];
        absorption = new float[voxels.length];
        fullCells = new boolean[size * size * size];
    }

    /** The volume follows the camera in four-block steps. */
    static int origin(double camera, int size) {
        return (int) Math.floor(camera / 4.0) * 4 - size / 2;
    }

    /** Background snapshots yield between small batches; urgent edits may finish at once. */
    boolean advance(int budget, long deadline) {
        BlockPos.MutableBlockPos position = new BlockPos.MutableBlockPos();
        int end = Math.min(cursor + budget, size * size * size);
        for (; cursor < end; cursor++) {
            if ((cursor & 127) == 0 && System.nanoTime() >= deadline) {
                break;
            }
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
            voxels[offset + 3] = level.getBrightness(LightLayer.SKY, position) / 32.0f;
            float[] filter = LightMaterials.absorption(state);
            if (filter != null && !settings.coloured) {
                // Without coloured lighting glass keeps its density but loses its hue.
                float grey = (filter[0] + filter[1] + filter[2]) / 3.0f;
                filter = new float[] {grey, grey, grey, filter[3]};
            }
            if (filter != null) {
                System.arraycopy(filter, 0, absorption, offset, 4);
                transmittingCells++;
                occluders[cursor] = state;
                for (AABB shape : state.getShape(level, position).toAabbs()) {
                    glassBoxes.add(new Box(shape.move(x, y, z), cursor, false));
                }
            }
            if (state.isAir() || state.getLightBlock() == 0) {
                continue;
            }
            occluders[cursor] = state;
            int color = state.getMapColor(level, position).col;
            voxels[offset] = LINEAR[(color >> 16) & 255];
            voxels[offset + 1] = LINEAR[(color >> 8) & 255];
            voxels[offset + 2] = LINEAR[color & 255];
            boolean full = state.isCollisionShapeFullBlock(level, position);
            fullCells[cursor] = full;
            if (full) {
                // Full cubes need no temporary AABB, list or Box during validation.
                // Expand them only if this snapshot actually replaces the GPU scene.
                fullCellCount++;
                voxels[offset + 3] += 1.0f;
                continue;
            }
            List<AABB> shapes = state.getShape(level, position).toAabbs();
            double occupied = 0.0;
            for (AABB shape : shapes) {
                occupied += shape.getXsize() * shape.getYsize() * shape.getZsize();
                partialBoxes.add(new Box(shape.move(x, y, z), cursor, false));
            }
            if (occupied >= 0.20) {
                voxels[offset + 3] += 1.0f;
            }
        }
        return cursor >= size * size * size;
    }

    /** Occluder at a world cell, or null outside this snapshot. */
    BlockState occluder(int x, int y, int z) {
        x -= originX;
        y -= originY;
        z -= originZ;
        if (x < 0 || y < 0 || z < 0 || x >= size || y >= size || z >= size) {
            return null;
        }
        return occluders[(z * size + y) * size + x];
    }

    /** Repeated scans of unchanged blocks must not clear valid maps or restart GI. */
    boolean sameContent(SceneVolume other) {
        return other != null && originX == other.originX && originY == other.originY
            && originZ == other.originZ && Arrays.equals(fullCells, other.fullCells)
            && partialBoxes.equals(other.partialBoxes)
            && glassBoxes.equals(other.glassBoxes) && Arrays.equals(voxels, other.voxels)
            && Arrays.equals(absorption, other.absorption);
    }

    /** Cull internal full-cube faces while preserving slab, stair and fence boxes. */
    float[] mesh() {
        return mesh(partialBoxes, size, fullCells, fullCellCount);
    }

    /** Recreate cubes in their original cell order, interleaved with partial shapes. */
    static float[] mesh(List<Box> partial, int size, boolean[] full, int fullCount) {
        List<Box> geometry = new ArrayList<>(partial.size() + fullCount);
        int next = 0;
        for (int owner = 0; owner < full.length; owner++) {
            if (full[owner]) {
                int x = owner % size;
                int y = (owner / size) % size;
                int z = owner / (size * size);
                geometry.add(new Box(new AABB(x, y, z, x + 1, y + 1, z + 1), owner, true));
            }
            while (next < partial.size() && partial.get(next).owner == owner) {
                geometry.add(partial.get(next++));
            }
        }
        return mesh(geometry, size, full);
    }

    /** First glass depth prevents tinting receivers on the light-facing side. */
    float[] glassMesh() {
        return mesh(glassBoxes, size, fullCells);
    }

    /** Box owners are cell indices in a size^3 cube whose full cells are flagged. */
    static float[] mesh(List<Box> geometry, int size, boolean[] fullCells) {
        int[][] neighbours = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
        int[][] faces = {{1,3,7,5},{0,4,6,2},{2,6,7,3},{0,1,5,4},{4,5,7,6},{0,2,3,1}};
        int[] order = {0,1,2,0,2,3};
        int[] masks = new int[geometry.size()];
        int floats = 0;
        // Count exposed faces first. Dense terrain used to allocate all six
        // faces for every cube, then allocate a second array after culling.
        for (int index = 0; index < geometry.size(); index++) {
            Box box = geometry.get(index);
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
                masks[index] |= 1 << face;
                floats += 24;
            }
        }
        float[] vertices = new float[floats];
        int count = 0;
        float[][] corners = new float[8][3];
        for (int index = 0; index < geometry.size(); index++) {
            if (masks[index] == 0) {
                continue;
            }
            Box box = geometry.get(index);
            AABB b = box.bounds;
            for (int corner = 0; corner < 8; corner++) {
                corners[corner][0] = (float)((corner & 1) == 0 ? b.minX : b.maxX);
                corners[corner][1] = (float)((corner & 2) == 0 ? b.minY : b.maxY);
                corners[corner][2] = (float)((corner & 4) == 0 ? b.minZ : b.maxZ);
            }
            for (int face = 0; face < 6; face++) {
                if ((masks[index] & (1 << face)) == 0) {
                    continue;
                }
                for (int corner : order) {
                    float[] point = corners[faces[face][corner]];
                    vertices[count++] = point[0];
                    vertices[count++] = point[1];
                    vertices[count++] = point[2];
                    vertices[count++] = box.owner;
                }
            }
        }
        return vertices;
    }

}
