package local.simpleshader.lighting;

import java.lang.management.ManagementFactory;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.zip.CRC32;
import net.minecraft.world.phys.AABB;

/** Compare production occluder meshes with pre-optimization vertex fingerprints.
 * Solid interiors, holes and slabs exercise culling and partial-block faces.
 * Allocations are measured after warming; elapsed time is diagnostic only.
 */
public final class CompanionMeshProbe {
    private static final int SIZE = 24;
    private static final int RUNS = 24;
    private static final int[] LENGTHS = {82944, 317568, 318480, 321984};
    private static final long[] CHECKSUMS = {2393267718L, 2422961011L, 28772794L, 1640955324L};

    /** Build deterministic connected terrain without relying on a live world. */
    private static List<SceneVolume.Box> geometry(boolean[] full, int seed) {
        List<SceneVolume.Box> boxes = new ArrayList<>();
        Random random = new Random(seed);
        for (int z = 0; z < SIZE; z++) {
            for (int y = 0; y < SIZE; y++) {
                for (int x = 0; x < SIZE; x++) {
                    int owner = (z * SIZE + y) * SIZE + x;
                    boolean solid = y < SIZE / 2 || x == 0 || z == 0;
                    if (seed != 0 && random.nextInt(9) == 0) {
                        solid = !solid;
                    }
                    if (!solid) {
                        continue;
                    }
                    boolean cube = seed == 0 || random.nextInt(27) != 0;
                    full[owner] = cube;
                    double top = y + (cube ? 1.0 : 0.5);
                    boxes.add(new SceneVolume.Box(new AABB(x, y, z, x + 1, top, z + 1), owner, cube));
                }
            }
        }
        return boxes;
    }

    /** Hash raw float bytes in vertex order, including the owner attribute. */
    private static long checksum(float[] mesh) {
        CRC32 crc = new CRC32();
        for (float value : mesh) {
            int bits = Float.floatToIntBits(value);
            for (int shift = 0; shift < 32; shift += 8) {
                crc.update((bits >>> shift) & 255);
            }
        }
        return crc.getValue();
    }

    public static void main(String[] arguments) {
        var bean = (com.sun.management.ThreadMXBean) ManagementFactory.getThreadMXBean();
        bean.setThreadAllocatedMemoryEnabled(true);
        long thread = Thread.currentThread().threadId();
        for (int seed = 0; seed < CHECKSUMS.length; seed++) {
            boolean[] full = new boolean[SIZE * SIZE * SIZE];
            List<SceneVolume.Box> boxes = geometry(full, seed);
            for (int warm = 0; warm < 12; warm++) {
                SceneVolume.mesh(boxes, SIZE, full);
            }
            long allocated = bean.getThreadAllocatedBytes(thread);
            long start = System.nanoTime();
            float[] mesh = null;
            for (int run = 0; run < RUNS; run++) {
                mesh = SceneVolume.mesh(boxes, SIZE, full);
            }
            long nanos = System.nanoTime() - start;
            long bytes = bean.getThreadAllocatedBytes(thread) - allocated;
            long crc = checksum(mesh);
            if (mesh.length != LENGTHS[seed] || crc != CHECKSUMS[seed]) {
                throw new IllegalStateException("Occluder mesh changed for fixture " + seed);
            }
            // Compact snapshots must expand to the same pre-recorded triangles.
            // Reflection lets this probe still measure an older baseline JAR.
            boolean compactVerified = false;
            try {
                var compact = SceneVolume.class.getDeclaredMethod("mesh", List.class,
                    int.class, boolean[].class, int.class);
                List<SceneVolume.Box> partial = boxes.stream().filter(box -> !box.full()).toList();
                int cubes = boxes.size() - partial.size();
                float[] expanded = (float[]) compact.invoke(null, partial, SIZE, full, cubes);
                if (expanded.length != LENGTHS[seed] || checksum(expanded) != CHECKSUMS[seed]) {
                    throw new IllegalStateException("Compact snapshot changed geometry for fixture " + seed);
                }
                compactVerified = true;
            } catch (NoSuchMethodException baseline) {
                // Baseline snapshots store all full-cube boxes eagerly.
            } catch (ReflectiveOperationException error) {
                throw new IllegalStateException("Cannot verify compact snapshot", error);
            }
            System.out.println("{\"seed\":" + seed + ",\"floats\":" + mesh.length
                + ",\"crc\":" + crc + ",\"allocated_bytes_per_mesh\":" + bytes / RUNS
                + ",\"compact_snapshot_verified\":" + compactVerified
                + ",\"milliseconds_per_mesh\":" + nanos / (RUNS * 1.0e6) + "}");
        }
    }
}
