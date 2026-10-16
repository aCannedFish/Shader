package local.simpleshader.lighting;

import java.util.HashSet;
import java.util.Set;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.SectionPos;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.Vec3;

/** Detect edits within the player's reach on the frame they happen. Clients get
 * no cheap block-change feed, so the box around the camera is compared with the
 * previous frame's snapshot; distant changes wait for the periodic scans.
 */
final class BlockWatch {
    private static final int RADIUS = 6;
    private static final int SIDE = RADIUS * 2 + 1;
    private BlockState[] previous = new BlockState[SIDE * SIDE * SIDE];
    private BlockState[] current = new BlockState[SIDE * SIDE * SIDE];
    private ClientLevel level;
    private int minX;
    private int minY;
    private int minZ;

    /** Sections containing changed cells; empty when nothing changed. */
    Set<Long> poll(ClientLevel world, Vec3 camera) {
        int x0 = (int) Math.floor(camera.x) - RADIUS;
        int y0 = (int) Math.floor(camera.y) - RADIUS;
        int z0 = (int) Math.floor(camera.z) - RADIUS;
        Set<Long> changed = Set.of();
        BlockPos.MutableBlockPos position = new BlockPos.MutableBlockPos();
        for (int index = 0; index < current.length; index++) {
            int x = x0 + index % SIDE;
            int y = y0 + (index / SIDE) % SIDE;
            int z = z0 + index / (SIDE * SIDE);
            BlockState state = world.getBlockState(position.set(x, y, z));
            current[index] = state;
            int px = x - minX;
            int py = y - minY;
            int pz = z - minZ;
            if (world == level && px >= 0 && py >= 0 && pz >= 0 && px < SIDE && py < SIDE && pz < SIDE
                && previous[(pz * SIDE + py) * SIDE + px] != state) {
                if (changed.isEmpty()) {
                    changed = new HashSet<>();
                }
                changed.add(SectionPos.asLong(x >> 4, y >> 4, z >> 4));
            }
        }
        BlockState[] swap = previous;
        previous = current;
        current = swap;
        level = world;
        minX = x0;
        minY = y0;
        minZ = z0;
        return changed;
    }
}
