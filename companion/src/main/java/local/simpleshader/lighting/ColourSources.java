package local.simpleshader.lighting;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.phys.Vec3;

/** Track visible emitter hues independently of the small, expensive GI volume.
 * Empty palettes are skipped. Old section results remain usable while the next
 * bounded scan runs, so moving the camera never clears the colour field.
 */
final class ColourSources {
    static final int LIMIT = 128;
    record Source(int x, int y, int z, int emission, float r, float g, float b, BlockState state) {}
    private record Section(int x, int y, int z) {
        double distance(Vec3 camera) {
            double dx = x * 16 + 8 - camera.x;
            double dy = y * 16 + 8 - camera.y;
            double dz = z * 16 + 8 - camera.z;
            return dx * dx + dy * dy + dz * dz;
        }
    }

    private final Map<Section, List<Source>> sections = new HashMap<>();
    private final ArrayDeque<Section> queue = new ArrayDeque<>();
    private long nextScan;
    private Vec3 centre = Vec3.ZERO;
    private List<Source> published = List.of();

    /** Return a new immutable list only when source data or selection changes. */
    List<Source> advance(ClientLevel level, Vec3 camera, int viewDistance) {
        long start = System.nanoTime();
        boolean changed = false;
        if (queue.isEmpty() && (start >= nextScan || camera.distanceToSqr(centre) >= 16.0)) {
            changed = camera.distanceToSqr(centre) >= 16.0;
            centre = camera;
            int radius = Math.min(128, Math.max(64, viewDistance * 16 + 16));
            int minX = Math.floorDiv((int)Math.floor(camera.x) - radius, 16);
            int maxX = Math.floorDiv((int)Math.floor(camera.x) + radius, 16);
            int minZ = Math.floorDiv((int)Math.floor(camera.z) - radius, 16);
            int maxZ = Math.floorDiv((int)Math.floor(camera.z) + radius, 16);
            int minY = Math.floorDiv((int)Math.floor(camera.y) - 48, 16);
            int maxY = Math.floorDiv((int)Math.floor(camera.y) + 48, 16);
            changed |= sections.keySet().removeIf(section -> section.x < minX || section.x > maxX
                || section.z < minZ || section.z > maxZ || section.y < minY || section.y > maxY);
            List<Section> work = new ArrayList<>();
            for (int x = minX; x <= maxX; x++) {
                for (int z = minZ; z <= maxZ; z++) {
                    if (!level.hasChunk(x, z)) {
                        continue;
                    }
                    for (int y = minY; y <= maxY; y++) {
                        work.add(new Section(x, y, z));
                    }
                }
            }
            work.sort(Comparator.comparingDouble(section -> section.distance(camera)));
            queue.addAll(work);
            nextScan = start + 250_000_000L;
        }
        // Recolouring or switching a known emitter must not wait for the whole
        // loaded-chunk scan. Only changed sections need their palette reread.
        BlockPos.MutableBlockPos position = new BlockPos.MutableBlockPos();
        for (Source source : published) {
            position.set(source.x, source.y, source.z);
            if (level.hasChunk(source.x >> 4, source.z >> 4)
                && level.getBlockState(position) != source.state) {
                Section key = new Section(source.x >> 4, source.y >> 4, source.z >> 4);
                queue.remove(key);
                queue.addFirst(key);
            }
        }
        int checks = 0;
        int cells = 0;
        while (!queue.isEmpty() && checks++ < 512 && cells < 32768) {
            Section key = queue.removeFirst();
            LevelChunk chunk = level.getChunkSource().getChunkNow(key.x, key.z);
            int index = chunk == null ? -1 : key.y - Math.floorDiv(chunk.getMinY(), 16);
            LevelChunkSection[] available = chunk == null ? null : chunk.getSections();
            List<Source> found = List.of();
            if (available != null && index >= 0 && index < available.length) {
                LevelChunkSection section = available[index];
                if (!section.hasOnlyAir() && section.maybeHas(state -> state.getLightEmission() > 0)) {
                    found = read(section, key);
                    cells += 4096;
                }
            }
            List<Source> old = sections.getOrDefault(key, List.of());
            if (!found.equals(old)) {
                changed = true;
                if (found.isEmpty()) {
                    sections.remove(key);
                } else {
                    sections.put(key, found);
                }
            }
            if (System.nanoTime() - start >= 2_000_000L) {
                break;
            }
        }
        if (changed || camera.distanceToSqr(centre) >= 16.0) {
            List<Source> sources = new ArrayList<>();
            sections.values().forEach(sources::addAll);
            sources.sort(Comparator.comparingDouble(source -> {
                double dx = source.x + 0.5 - camera.x;
                double dy = source.y + 0.5 - camera.y;
                double dz = source.z + 0.5 - camera.z;
                return (dx * dx + dy * dy + dz * dz) / source.emission;
            }));
            published = List.copyOf(sources.subList(0, Math.min(LIMIT, sources.size())));
        }
        return published;
    }

    /** Palette tests avoid scanning ordinary air, rock and unlit terrain cells. */
    private static List<Source> read(LevelChunkSection section, Section key) {
        List<Source> sources = new ArrayList<>();
        for (int z = 0; z < 16; z++) {
            for (int y = 0; y < 16; y++) {
                for (int x = 0; x < 16; x++) {
                    BlockState state = section.getBlockState(x, y, z);
                    int emission = state.getLightEmission();
                    if (emission > 0) {
                        float[] colour = LightMaterials.emission(state);
                        sources.add(new Source(key.x * 16 + x, key.y * 16 + y, key.z * 16 + z,
                            emission, colour[0], colour[1], colour[2], state));
                    }
                }
            }
        }
        return sources;
    }
}
