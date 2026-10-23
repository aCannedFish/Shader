package local.simpleshader.metadata;

import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.TreeSet;
import net.minecraft.SharedConstants;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.Property;

/** Sample immutable vanilla offset functions at synthetic positions. No save,
 * game client, block getter or actual world coordinates are accessed.
 */
public final class ExportOffsetProfiles {
    private ExportOffsetProfiles() {}

    private static <T extends Comparable<T>> String valueName(Property<T> property, Comparable<?> value) {
        return property.getName(property.getValueClass().cast(value));
    }

    private static JsonObject properties(BlockState state) {
        JsonObject result = new JsonObject();
        for (var entry : state.getValues().entrySet()) {
            result.addProperty(entry.getKey().getName(), valueName(entry.getKey(), entry.getValue()));
        }
        return result;
    }

    /** Check all synthetic samples against an affine grid, preserving each axis. */
    private static JsonObject axis(TreeSet<Double> values) {
        JsonObject result = new JsonObject();
        int count = values.size();
        double low = values.first();
        double high = values.last();
        double maximumError = 0.0;
        int index = 0;
        JsonArray samples = new JsonArray();
        for (double value : values) {
            double expected = count == 1 ? low : low + (high - low) * index / (count - 1);
            maximumError = Math.max(maximumError, Math.abs(value - expected));
            samples.add(value);
            index++;
        }
        result.addProperty("count", count);
        result.addProperty("minimum", low);
        result.addProperty("maximum", high);
        result.addProperty("affine_grid_error", maximumError);
        result.add("values", samples);
        return result;
    }

    public static void main(String[] arguments) throws Exception {
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();
        JsonArray result = new JsonArray();
        for (var block : BuiltInRegistries.BLOCK) {
            for (BlockState state : block.getStateDefinition().getPossibleStates()) {
                if (!state.hasOffsetFunction()) continue;
                var x = new TreeSet<Double>();
                var y = new TreeSet<Double>();
                var z = new TreeSet<Double>();
                for (int first = -16; first < 16; first++) {
                    for (int second = -16; second < 16; second++) {
                        var offset = state.getOffset(new BlockPos(first, first - second, second));
                        x.add(offset.x);
                        y.add(offset.y);
                        z.add(offset.z);
                    }
                }
                JsonObject entry = new JsonObject();
                entry.addProperty("block", BuiltInRegistries.BLOCK.getKey(block).toString());
                entry.add("properties", properties(state));
                JsonArray axes = new JsonArray();
                axes.add(axis(x));
                axes.add(axis(y));
                axes.add(axis(z));
                entry.add("axes", axes);
                int unknown = 0;
                for (int sample = 0; sample < 1024; sample++) {
                    var offset = state.getOffset(new BlockPos(1_000_003 + sample * 23,
                        -64 + sample % 127, -999_983 - sample * 29));
                    if (!x.contains(offset.x) || !y.contains(offset.y) || !z.contains(offset.z)) unknown++;
                }
                entry.addProperty("holdout_samples", 1024);
                entry.addProperty("holdout_unknown", unknown);
                result.add(entry);
            }
        }
        Files.writeString(Path.of(arguments[0]), new GsonBuilder().setPrettyPrinting().create().toJson(result));
        System.out.println("Exported immutable offset profiles: " + result.size() + " states");
    }
}
