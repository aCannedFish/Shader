package local.simpleshader.lighting;

import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.tags.FluidTags;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.phys.Vec3;

/** Cache the camera's water column and its surface skylight, independently of
 * view direction. A bounded scan runs after block movement or every five ticks;
 * camera motion within a block only updates the relative immersion depth.
 */
final class WaterMediumCache {
    static final float MAGIC = 1573.0f;
    static final int ATLAS_ROW = 7;
    private static final int MAX_DEPTH = 64;
    private final BlockPos.MutableBlockPos position = new BlockPos.MutableBlockPos();
    private final float[] data = new float[4];
    private ClientLevel level;
    private int lastX = Integer.MIN_VALUE;
    private int lastY;
    private int lastZ;
    private long lastTick;
    private double surfaceHeight;
    private float surfaceSky;
    private boolean valid;

    /** Reuse native fluid/light data without forcing chunks to load. */
    float[] update(ClientLevel world, Vec3 camera) {
        int x = (int)Math.floor(camera.x);
        int y = (int)Math.floor(camera.y);
        int z = (int)Math.floor(camera.z);
        long tick = world.getGameTime();
        if (world != level || x != lastX || y != lastY || z != lastZ || tick - lastTick >= 5) {
            level = world;
            lastX = x;
            lastY = y;
            lastZ = z;
            lastTick = tick;
            sample(world, x, y, z);
        }
        data[0] = valid ? (float)Math.max(0.0, surfaceHeight - camera.y) : 0.0f;
        data[1] = surfaceSky;
        data[2] = valid && camera.y < surfaceHeight ? 1.0f : 0.0f;
        data[3] = MAGIC;
        return data;
    }

    /** The light just above the water distinguishes open water from roofed pools.
     * Reaching the scan bound leaves the record invalid and selects shader fallback.
     */
    private void sample(ClientLevel world, int x, int y, int z) {
        valid = false;
        surfaceSky = 0.0f;
        position.set(x, y, z);
        if (!world.hasChunkAt(position) || !world.getFluidState(position).is(FluidTags.WATER)) {
            return;
        }
        for (int height = y; height < Math.min(y + MAX_DEPTH, world.getMaxY()); height++) {
            position.set(x, height, z);
            FluidState fluid = world.getFluidState(position);
            if (!fluid.is(FluidTags.WATER)) {
                surfaceSky = world.getBrightness(LightLayer.SKY, position) / 15.0f;
                valid = true;
                return;
            }
            surfaceHeight = height + fluid.getHeight(world, position);
        }
    }
}
