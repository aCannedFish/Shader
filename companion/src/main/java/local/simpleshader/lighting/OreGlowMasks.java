package local.simpleshader.lighting;

import com.mojang.blaze3d.platform.NativeImage;
import java.util.HashSet;
import java.util.Set;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.texture.TextureAtlas;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.data.AtlasIds;
import net.minecraft.resources.Identifier;

/** Mineral-only emission masks from the active block atlas. Rock colours are
 * matched against the host rock's entire palette, so its shifted noise pattern
 * cannot be mistaken for an ore vein. No game textures are bundled in the Mod.
 */
final class OreGlowMasks {
    static final int ROW = 8;
    static final int SIDE = 64;
    static final int MASK_TEXELS = SIDE * SIDE / 32;
    static final float MAGIC = 3142.0f;
    static final String[] ORES = {
        "coal_ore", "deepslate_coal_ore", "iron_ore", "deepslate_iron_ore",
        "copper_ore", "deepslate_copper_ore", "gold_ore", "deepslate_gold_ore",
        "redstone_ore", "deepslate_redstone_ore", "lapis_ore", "deepslate_lapis_ore",
        "emerald_ore", "deepslate_emerald_ore", "diamond_ore", "deepslate_diamond_ore",
        "nether_gold_ore", "nether_quartz_ore"
    };
    static final int MASK_START = 2 + ORES.length * 2;
    private final float[] data = new float[(MASK_START + ORES.length * MASK_TEXELS) * 4];
    private TextureAtlasSprite previous;
    private long revision;

    /** Sprite identities change on resource reload; ordinary frames do no work. */
    void advance(Minecraft client) {
        TextureAtlas atlas = client.getAtlasManager().getAtlasOrThrow(AtlasIds.BLOCKS);
        TextureAtlasSprite probe = sprite(atlas, ORES[0]);
        if (probe == previous) {
            return;
        }
        previous = probe;
        java.util.Arrays.fill(data, 0.0f);
        data[0] = MAGIC;
        data[1] = SIDE;
        data[2] = ORES.length;
        data[3] = MASK_START;
        for (int ore = 0; ore < ORES.length; ore++) {
            TextureAtlasSprite source = sprite(atlas, ORES[ore]);
            String host = ore >= 16 ? "netherrack" : ore % 2 == 0 ? "stone" : "deepslate";
            TextureAtlasSprite rock = sprite(atlas, host);
            if (source == atlas.missingSprite() || rock == atlas.missingSprite()
                || source.contents().isAnimated() || rock.contents().isAnimated()) {
                continue;
            }
            int side = source.contents().width();
            // Preserve pixel correspondence. Unsupported atlases stay unlit;
            // reducing a larger mask could accidentally illuminate rock pixels.
            if (side > SIDE || side != source.contents().height() || SIDE % side != 0) {
                continue;
            }
            NativeImage image = source.contents().getOriginalImage();
            int[] palette = palette(rock.contents().getOriginalImage());
            boolean[] mineral = new boolean[side * side];
            for (int y = 0; y < side; y++) {
                for (int x = 0; x < side; x++) {
                    mineral[y * side + x] = isMineral(image.getPixel(x, y), palette, ore);
                }
            }
            int metadata = (2 + ore * 2) * 4;
            float u = source.getU0();
            float v = source.getV0();
            // RGBA16F needs a split origin to retain atlas subpixel precision.
            data[metadata] = (float)Math.floor(u * 1024.0f) / 1024.0f;
            data[metadata + 1] = (float)Math.floor(v * 1024.0f) / 1024.0f;
            data[metadata + 2] = source.getU1() - u;
            data[metadata + 3] = source.getV1() - v;
            data[metadata + 4] = u - data[metadata];
            data[metadata + 5] = v - data[metadata + 1];
            for (int y = 0; y < SIDE; y++) {
                for (int x = 0; x < SIDE; x++) {
                    if (mineral[(y * side / SIDE) * side + x * side / SIDE]) {
                        int pixel = y * SIDE + x;
                        int component = (MASK_START + ore * MASK_TEXELS) * 4 + pixel / 8;
                        data[component] += 1 << (pixel % 8);
                    }
                }
            }
        }
        revision++;
    }

    private static TextureAtlasSprite sprite(TextureAtlas atlas, String name) {
        return atlas.getSprite(Identifier.fromNamespaceAndPath("minecraft", "block/" + name));
    }

    /** Deduplicate colours before testing each source pixel against the rock. */
    private static int[] palette(NativeImage image) {
        Set<Integer> colours = new HashSet<>();
        for (int y = 0; y < image.getHeight(); y++) {
            for (int x = 0; x < image.getWidth(); x++) {
                colours.add(image.getPixel(x, y) & 0xFFFFFF);
            }
        }
        return colours.stream().mapToInt(Integer::intValue).toArray();
    }

    /** Ignore grey vein shadows for coloured ores; coal keeps only dark inserts.
     * A conservative palette match takes precedence over emission in custom packs.
     */
    static boolean isMineral(int pixel, int[] rockPalette, int ore) {
        int r = pixel >> 16 & 255;
        int g = pixel >> 8 & 255;
        int b = pixel & 255;
        int maximum = Math.max(r, Math.max(g, b));
        int minimum = Math.min(r, Math.min(g, b));
        if ((pixel >>> 24) < 128 || (ore < 2 ? maximum > 76 : ore == 17 ? minimum < 105 : maximum - minimum <= 12)) {
            return false;
        }
        for (int rock : rockPalette) {
            int difference = Math.max(Math.abs(r - (rock >> 16 & 255)),
                Math.max(Math.abs(g - (rock >> 8 & 255)), Math.abs(b - (rock & 255))));
            if (difference <= 8) {
                return false;
            }
        }
        return true;
    }

    float[] data() {
        return data;
    }

    long revision() {
        return revision;
    }
}
