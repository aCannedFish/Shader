package local.simpleshader.lighting;

import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.item.DyeColor;
import net.minecraft.world.level.block.StainedGlassBlock;
import net.minecraft.world.level.block.StainedGlassPaneBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;

/** Authored emitter colours and passive RGB absorption, expressed in linear light. */
final class LightMaterials {
    private LightMaterials() {}

    /** Display RGB specifies hue; the block's current emission level supplies energy. */
    static float[] emission(BlockState state) {
        String name = BuiltInRegistries.BLOCK.getKey(state.getBlock()).getPath();
        float[] colour = switch (name) {
            case "torch", "wall_torch", "lantern", "candle", "candle_cake" -> rgb(1.0f, 0.88f, 0.67f);
            case "soul_torch", "soul_wall_torch", "soul_lantern", "soul_fire", "soul_campfire" -> rgb(0.38f, 0.72f, 1.0f);
            case "redstone_torch", "redstone_wall_torch" -> rgb(1.0f, 0.12f, 0.05f);
            case "sea_lantern", "beacon", "light" -> rgb(1.0f, 1.0f, 1.0f);
            case "glowstone", "redstone_lamp" -> rgb(1.0f, 0.82f, 0.49f);
            case "shroomlight", "jack_o_lantern" -> rgb(1.0f, 0.68f, 0.36f);
            case "fire", "campfire" -> rgb(1.0f, 0.71f, 0.38f);
            case "lava", "magma_block" -> rgb(1.0f, 0.36f, 0.08f);
            case "end_rod" -> rgb(1.0f, 0.96f, 0.86f);
            case "amethyst_cluster", "large_amethyst_bud", "medium_amethyst_bud", "small_amethyst_bud" -> rgb(0.74f, 0.46f, 1.0f);
            case "crying_obsidian", "respawn_anchor" -> rgb(0.67f, 0.24f, 1.0f);
            case "ochre_froglight" -> rgb(1.0f, 0.92f, 0.59f);
            case "verdant_froglight" -> rgb(0.70f, 1.0f, 0.66f);
            case "pearlescent_froglight" -> rgb(0.94f, 0.72f, 1.0f);
            case "glow_lichen", "glow_berries", "cave_vines", "cave_vines_plant" -> rgb(0.73f, 0.95f, 0.64f);
            case "sculk_catalyst", "sculk_sensor", "calibrated_sculk_sensor" -> rgb(0.20f, 0.65f, 0.85f);
            case "copper_torch", "copper_wall_torch", "copper_lantern", "copper_fire" -> rgb(0.36f, 1.0f, 0.65f);
            default -> name.endsWith("_candle") || name.endsWith("_candle_cake")
                ? rgb(1.0f, 0.88f, 0.67f) : rgb(1.0f, 0.95f, 0.85f);
        };
        for (int index = 0; index < 3; index++) {
            colour[index] = (float) Math.pow(colour[index], 2.2);
        }
        return colour;
    }

    /** Sigma_a = -log(T) / thickness. Alpha encodes full glass or pane connections. */
    static float[] absorption(BlockState state) {
        DyeColor dye;
        int shape = 1;
        float thickness = 1.0f;
        if (state.getBlock() instanceof StainedGlassBlock glass) {
            dye = glass.getColor();
        } else if (state.getBlock() instanceof StainedGlassPaneBlock pane) {
            dye = pane.getColor();
            int connections = (state.getValue(BlockStateProperties.EAST) ? 1 : 0)
                | (state.getValue(BlockStateProperties.WEST) ? 2 : 0)
                | (state.getValue(BlockStateProperties.SOUTH) ? 4 : 0)
                | (state.getValue(BlockStateProperties.NORTH) ? 8 : 0);
            shape = 2 + connections;
            thickness = 0.125f;
        } else {
            return null;
        }
        int tint = dye.getTextureDiffuseColor();
        float[] transmission = rgb(((tint >> 16) & 255) / 255.0f,
            ((tint >> 8) & 255) / 255.0f, (tint & 255) / 255.0f);
        float peak = Math.max(transmission[0], Math.max(transmission[1], transmission[2]));
        for (int index = 0; index < 3; index++) {
            float hue = transmission[index] / Math.max(peak, 0.001f);
            transmission[index] = (0.35f + 0.60f * peak) * (0.12f + 0.88f * (float) Math.pow(hue, 1.5));
        }
        if (dye == DyeColor.WHITE || dye == DyeColor.LIGHT_GRAY || dye == DyeColor.GRAY || dye == DyeColor.BLACK) {
            float neutral = switch (dye) {
                case WHITE -> 0.94f;
                case LIGHT_GRAY -> 0.80f;
                case GRAY -> 0.60f;
                default -> 0.28f;
            };
            transmission = rgb(neutral, neutral, neutral);
        }
        return new float[] {-(float) Math.log(transmission[0]) / thickness,
            -(float) Math.log(transmission[1]) / thickness,
            -(float) Math.log(transmission[2]) / thickness, shape};
    }

    private static float[] rgb(float red, float green, float blue) {
        return new float[] {red, green, blue};
    }
}
