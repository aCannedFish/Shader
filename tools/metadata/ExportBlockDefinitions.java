package local.simpleshader.metadata;

import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.nio.file.Files;
import java.nio.file.Path;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.Property;

/** Build-time exporter of immutable vanilla registry definitions. No client,
 * save, world position, rendering context or companion Mod is constructed.
 */
public final class ExportBlockDefinitions {
    private ExportBlockDefinitions() {}

    /** Preserve Minecraft's canonical property spelling, including enum values. */
    private static <T extends Comparable<T>> String propertyName(Property<T> property, Comparable<?> value) {
        return property.getName(property.getValueClass().cast(value));
    }

    /** Serialize defaults and variants through the same canonical property API. */
    private static JsonObject properties(BlockState state) {
        JsonObject result = new JsonObject();
        for (var entry : state.getValues().entrySet()) {
            result.addProperty(entry.getKey().getName(), propertyName(entry.getKey(), entry.getValue()));
        }
        return result;
    }

    public static void main(String[] arguments) throws Exception {
        if (arguments.length != 1) throw new IllegalArgumentException("Output JSON path required");
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();
        // Provider registration is immutable client metadata. Reading its keys
        // creates no renderer, world, live block entity or GPU context.
        var providerField = net.minecraft.client.renderer.blockentity.BlockEntityRenderers.class.getDeclaredField("PROVIDERS");
        providerField.setAccessible(true);
        var providers = (java.util.Map<?, ?>)providerField.get(null);
        var renderedTypes = new java.util.ArrayList<net.minecraft.world.level.block.entity.BlockEntityType<?>>();
        for (Object type : providers.keySet()) {
            renderedTypes.add((net.minecraft.world.level.block.entity.BlockEntityType<?>)type);
        }
        JsonObject result = new JsonObject();
        result.addProperty("schema_version", 2);
        result.addProperty("source", "Immutable Minecraft registry; no world or GPU context");
        net.minecraft.client.renderer.ItemBlockRenderTypes.setCutoutLeaves(true);
        JsonObject dyes = new JsonObject();
        for (var dye : net.minecraft.world.item.DyeColor.values()) {
            dyes.addProperty(dye.getName(), dye.getTextureDiffuseColor());
        }
        result.add("dye_texture_colours", dyes);
        JsonArray blocks = new JsonArray();
        int states = 0;
        for (var block : BuiltInRegistries.BLOCK) {
            JsonObject definition = new JsonObject();
            definition.addProperty("name", BuiltInRegistries.BLOCK.getKey(block).toString());
            definition.add("defaults", properties(block.defaultBlockState()));
            JsonArray variants = new JsonArray();
            for (BlockState state : block.getStateDefinition().getPossibleStates()) {
                JsonObject item = new JsonObject();
                item.add("properties", properties(state));
                item.addProperty("emission", state.getLightEmission());
                item.addProperty("air", state.isAir());
                item.addProperty("has_model_offset", state.hasOffsetFunction());
                item.addProperty("can_occlude", state.canOcclude());
                boolean renderedEntity = false;
                for (var type : renderedTypes) renderedEntity |= type.isValid(state);
                item.addProperty("rendered_block_entity", renderedEntity);
                item.addProperty("render_shape", state.getRenderShape().name());
                item.addProperty("render_layer", net.minecraft.client.renderer.ItemBlockRenderTypes.getChunkRenderType(state).name());
                variants.add(item);
                states++;
            }
            definition.add("states", variants);
            blocks.add(definition);
        }
        result.add("blocks", blocks);
        result.addProperty("block_count", blocks.size());
        result.addProperty("state_count", states);
        Files.writeString(Path.of(arguments[0]), new GsonBuilder().setPrettyPrinting().create().toJson(result));
        System.out.println("Exported immutable definitions: " + blocks.size() + " blocks, " + states + " states");
    }
}
