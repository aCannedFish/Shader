package local.simpleshader.preview;

import java.io.File;
import java.awt.image.BufferedImage;
import javax.imageio.ImageIO;
import org.lwjgl.glfw.GLFW;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import net.minecraft.client.CloudStatus;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.LeavesBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;
import net.minecraft.world.level.block.state.properties.DoubleBlockHalf;
import net.minecraft.world.level.block.state.properties.BedPart;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.config.ConfigTracker;
import net.minecraftforge.fml.config.ModConfig;
import net.minecraft.world.level.storage.LevelResource;
import com.electronwill.nightconfig.core.file.CommentedFileConfig;

/**
 * Captures a small suite in an isolated copy of a world, then exits the client.
 * Server-side world edits establish the scene; rendering and readback remain
 * Minecraft/OptiFine's own implementation. This helper is used only for capture.
 */
@Mod("simpleshader_preview")
public final class CaptureScenes {
    private static final String[][] SCENES = selectScenes(new String[][] {
        {"stability_air_sequence_0", "11790", "1786.1284 63 -152.6893 75 0"},
        {"stability_air_sequence_1", "11790", "1786.1284 63 -152.6893 75 0"},
        {"stability_air_sequence_2", "11790", "1786.1284 63 -152.6893 75 0"},
        {"stability_air_sequence_3", "11790", "1786.1284 63 -152.6893 75 0"},
        {"stability_air_sequence_4", "11790", "1786.1284 63 -152.6893 75 0"},
        {"stability_air_sequence_5", "11790", "1786.1284 63 -152.6893 75 0"},
        {"stability_water_sequence_0", "6000", "101 77.4 15 180 -18"},
        {"stability_water_sequence_1", "6000", "101 77.4 15 180 -18"},
        {"stability_water_sequence_2", "6000", "101 77.4 15 180 -18"},
        {"stability_water_sequence_3", "6000", "101 77.4 15 180 -18"},
        {"stability_water_sequence_4", "6000", "101 77.4 15 180 -18"},
        {"stability_water_sequence_5", "6000", "101 77.4 15 180 -18"},
        {"caustics_pool_day", "6000", "150 77 12 180 24"},
        {"caustics_pool_night", "18000", "150 77 12 180 24"},
        {"visibility_cave_day", "6000", "-124 82 58 180 8"},
        {"visibility_cave_night", "18000", "-124 82 58 180 8"},
        {"lens_sun_open", "0", "0 100 17 250 -10"},
        {"lens_sun_blocked", "0", "0 100 17 250 -10"},
        {"lens_sun_behind", "0", "0 100 17 70 -10"},
        {"lens_sun_lowview", "0", "0 100 17 250 15"},
        {"shadow_path_sunset", "11790", "1786.1284 63 -152.6893 62.2706 2.1"},
        {"shadow_path_motion", "11790", "1786.3284 63 -152.5893 62.2706 2.1"},
        {"shadow_path_late", "12500", "1786.1284 63 -152.6893 62.2706 2.1"},
        {"shadow_path_noon", "6000", "1786.1284 63 -152.6893 62.2706 2.1"},
        {"shadow_path_photo", "11790", "1786.1284 63 -152.6893 75 23"},
        {"sunshafts_sunrise", "23500", "-264 82 72 235 2"},
        {"sunshafts_sunrise_motion", "23500", "-264 82 72 235 2"},
        {"sunshafts_oblique", "0", "-264 82 72 235 2"},
        {"sunshafts_oblique_motion", "0", "-263.7 82 72.1 235 2"},
        {"sunshafts_sunset", "12500", "-220 82 72 125 2"},
        {"sunshafts_noon", "6000", "-264 82 72 235 2"},
        {"sunshafts_night", "18000", "-264 82 72 235 2"},
        {"sunshafts_room", "1000", "-94 82 54 180 12"},
        {"lighting_gi_room", "18000", "-94 82 54 180 12"},
        {"lighting_gi_two_lights", "18000", "-94 82 54 180 12"},
        {"rim_sunset", "12500", "-150 83 0 90 -4"},
        {"rim_sunset_late", "13800", "-150 83 0 90 -4"},
        {"rim_night", "18000", "-150 83 0 90 -4"},
        {"rim_sunrise_early", "22500", "-190 83 0 270 -4"},
        {"rim_sunrise", "23500", "-190 83 0 270 -4"},
        {"rim_day", "6000", "-150 83 0 90 -4"},
        {"rim_user_north", "13800", "1765 65 -134 180 0"},
        {"rim_user_west", "13800", "1765 65 -134 90 0"},
        {"rim_user_east", "13800", "1765 65 -134 270 0"},
        {"rim_user_south", "13800", "1765 65 -134 0 0"},
        {"style_village_night", "18000", "1790 93 -130 93.7 38.4"},
        {"style_village_day", "6000", "1790 93 -130 93.7 38.4"},
        {"style_village_ground", "18000", "1779 66 -139 93.7 8"},
        {"sky_sun", "6000", "0 100 17 180 -88"},
        {"sky_sunrise", "23500", "0 100 17 270 -4"},
        {"sky_sunset", "12500", "0 100 17 90 -4"},
        {"sky_moon", "18000", "0 100 17 180 -88"},
        {"sky_moon_quarter", "66000", "0 100 17 180 -88"},
        {"sky_moon_new", "114000", "0 100 17 180 -88"},
        {"sky_zenith", "2000", "233 200 24 180 -90"},
        {"sky_nadir", "2000", "233 600 24 180 90"},
        {"lighting_bed_day", "6000", "-75 83 54 180 26"},
        {"lighting_bed_night", "18000", "-75 83 54 180 26"},
        {"lighting_bed_lit", "18000", "-75 83 54 180 26"},
        {"lighting_shadow_day_dark", "2000", "-70 86 63 180 28"},
        {"lighting_shadow_day_lit", "2000", "-70 86 63 180 28"},
        {"lighting_shadow_sunrise_dark", "500", "-70 86 63 180 28"},
        {"lighting_shadow_sunset_dark", "11000", "-70 86 63 180 28"},
        {"lighting_shadow_night_dark", "22000", "-70 86 63 180 28"},
        {"lighting_shadow_night_lit", "22000", "-70 86 63 180 28"},
        {"clouds_night", "18000", "0 160 17 180 -20"},
        {"sky_direction_0", "6000", "233 92 24 0 6"},
        {"sky_direction_45", "6000", "233 92 24 45 6"},
        {"sky_direction_90", "6000", "233 92 24 90 6"},
        {"sky_direction_135", "6000", "233 92 24 135 6"},
        {"sky_direction_180", "6000", "233 92 24 180 6"},
        {"sky_direction_225", "6000", "233 92 24 225 6"},
        {"sky_direction_270", "6000", "233 92 24 270 6"},
        {"sky_direction_315", "6000", "233 92 24 315 6"},
        {"daylight", "6000", "0 84 17 180 12"},
        {"sunset", "12000", "0 84 17 180 12"},
        {"night", "18000", "0 84 17 180 12"},
        {"water", "6000", "8 82.5 8 135 10"},
        {"underwater", "6000", "7 77.8 1 180 0"},
        {"clouds", "6000", "0 160 17 180 -20"},
        {"fog", "6000", "0 84 17 180 0"},
        {"cloud_below", "6000", "0 180 17 180 -24"},
        {"cloud_inside", "6000", "0 198.38 17 180 0"},
        {"cloud_above", "6000", "0 216 17 180 24"},
        {"cloud_motion", "6000", "0 160 17 180 -20"},
        {"water_reflection", "6000", "8 82.0 4 180 7"},
        {"water_reflection_motion", "6000", "8 82.0 4 180 7"},
        {"water_grazing", "6000", "8 79.8 4 180 2"},
        {"water_grazing_motion", "6000", "8 79.8 4 180 2"},
        {"water_shallow", "6000", "5.5 82.4 3 180 60"},
        {"water_depth_steps", "6000", "8 84 6 180 52"},
        {"water_depth_steps_motion", "6000", "8 84 6 180 52"},
        {"water_cave_dark", "6000", "50 82.0 9 180 8"},
        {"water_cave_lit", "6000", "50 82.0 9 180 8"},
        {"water_cave_night", "18000", "50 82.0 9 180 8"},
        {"water_glass", "6000", "8 82.0 4 180 7"},
        {"local_shadow_dark", "6000", "-32 83 13 180 27"},
        {"local_shadow_lit", "6000", "-32 83 13 180 27"},
        {"local_light_night", "18000", "-32 83 13 180 27"},
        {"vegetation", "8000", "0 83.5 68 180 16"},
        {"vegetation_motion", "8000", "0 83.5 68 180 16"},
        {"vegetation_roots", "8000", "0 82 50 180 27"},
        {"vegetation_shadows", "8000", "0 87 68 180 38"},
        {"underwater_shallow", "6000", "101 76 15 180 0"},
        {"underwater_deep", "6000", "101 62 15 180 0"},
        {"underwater_air", "6000", "101 76 15 180 -45"},
        {"underwater_air_deep", "6000", "101 62 15 180 -55"},
        {"underwater_interface", "6000", "101 77.4 15 180 -18"},
        {"underwater_interface_motion", "6000", "101 77.4 15 180 -18"},
        {"underwater_shafts_noon", "6000", "101 76 15 180 -12"},
        {"underwater_shafts_morning", "2000", "101 76 15 180 -12"},
        {"underwater_shafts_night", "18000", "101 76 15 180 -12"},
        {"underwater_cave", "6000", "50 79 3 180 -12"},
        {"underwater_magma_dark", "18000", "106 56 9 180 18"},
        {"underwater_magma_lit", "18000", "106 56 9 180 18"},
        {"water_far", "6000", "8 84 -86 0 2"}
    });

    /** Restrict integration captures while preserving the suite's case order. */
    private static String[][] selectScenes(String[][] all) {
        String selection = System.getProperty("simpleshader.preview.scenes", "");
        if (selection.isEmpty()) {
            return all;
        }
        Set<String> names = Set.of(selection.split(","));
        return java.util.Arrays.stream(all).filter(scene -> names.contains(scene[0]))
            .toArray(String[][]::new);
    }

    private final AtomicBoolean commandsReady = new AtomicBoolean(false);
    private int loadedTicks;
    private int scene = -1;
    private volatile String selectedCamera;
    private boolean rebuilt;
    private long sceneStart;
    private long finishStart;
    private long lastCapture;
    private int scheduledTicks;
    private boolean requested;

    /** Select a robust occupied cell for interior/boundary capture views. */
    private static float fraction(float value) {
        return value - (float) Math.floor(value);
    }

    private static float cellHash(float x, float z) {
        float a = fraction(x * 0.1031f);
        float b = fraction(z * 0.1031f);
        float c = a;
        float product = a * (b + 33.33f) + b * (c + 33.33f) + c * (a + 33.33f);
        a += product;
        b += product;
        c += product;
        return fraction((a + b) * c);
    }

    /** Continuous weather interpolation matching cloud_density.glsl. */
    private static float weatherNoise(float x, float z) {
        float ix = (float) Math.floor(x);
        float iz = (float) Math.floor(z);
        float u = fraction(x);
        float v = fraction(z);
        u = u * u * (3.0f - 2.0f * u);
        v = v * v * (3.0f - 2.0f * v);
        float lower = cellHash(ix, iz) * (1.0f - u) + cellHash(ix + 1, iz) * u;
        float upper = cellHash(ix, iz + 1) * (1.0f - u) + cellHash(ix + 1, iz + 1) * u;
        return lower * (1.0f - v) + upper * v;
    }

    /** Read the baked field rather than inventing geometry for the cloud test. */
    private static float volumeNoise(BufferedImage atlas, float x, float y, float z) {
        float[] p = {fraction(x) * 64.0f, fraction(y) * 64.0f, fraction(z) * 64.0f};
        float sum = 0.0f;
        for (int dz = 0; dz <= 1; dz++) {
            for (int dy = 0; dy <= 1; dy++) {
                for (int dx = 0; dx <= 1; dx++) {
                    int vx = ((int) Math.floor(p[0]) + dx) % 64;
                    int vy = ((int) Math.floor(p[1]) + dy) % 64;
                    int vz = ((int) Math.floor(p[2]) + dz) % 64;
                    int pixel = atlas.getRGB((vz % 8) * 66 + vx + 1, (vz / 8) * 66 + vy + 1);
                    float weight = (dx == 0 ? 1.0f - fraction(p[0]) : fraction(p[0]))
                        * (dy == 0 ? 1.0f - fraction(p[1]) : fraction(p[1]))
                        * (dz == 0 ? 1.0f - fraction(p[2]) : fraction(p[2]));
                    sum += ((pixel >> 16) & 255) / 255.0f * weight;
                }
            }
        }
        return sum;
    }

    /** Match volume translation and select a dense region for traversal views. */
    private static String cloudCamera(String name) {
        float seconds = 0.0f;
        try {
            java.lang.reflect.Field time = Class.forName("net.optifine.shaders.Shaders")
                .getDeclaredField("frameTimeCounter");
            time.setAccessible(true);
            seconds = time.getFloat(null);
        } catch (ReflectiveOperationException unavailable) {
            System.out.println("SIMPLE_PREVIEW cloud time unavailable");
        }
        File asset = new File(Minecraft.getInstance().gameDirectory,
            "shaderpacks/SimpleShader/shaders/textures/sky-noise.png");
        try {
            BufferedImage atlas = ImageIO.read(asset);
            float best = -1.0f;
            float selectedX = 0.0f;
            float selectedZ = 0.0f;
            for (int z = -640; z <= 640; z += 32) {
                for (int x = -640; x <= 640; x += 32) {
                    float weather = weatherNoise(x / 1600.0f, z / 1600.0f) * 0.65f
                        + weatherNoise(x / 544.0f + 19.0f, z / 544.0f + 19.0f) * 0.35f;
                    float coverage = 0.50f + (weather - 0.5f) * 0.36f;
                    float value = (volumeNoise(atlas, x / 640.0f, 76.8f / 640.0f, z / 640.0f)
                        - (1.0f - coverage)) / 0.20f;
                    if (value > best) {
                        best = value;
                        selectedX = x;
                        selectedZ = z;
                    }
                }
            }
            float y = name.equals("cloud_inside") ? 332.8f
                : name.equals("cloud_above") ? 480.0f : 224.0f;
            int pitch = name.equals("cloud_inside") ? 0 : name.equals("cloud_above") ? 24 : -24;
            return (selectedX + seconds * 4.0f) + " " + y + " "
                + (selectedZ + seconds * 4.0f * 0.21f) + " 180 " + pitch;
        } catch (java.io.IOException unavailable) {
            throw new IllegalStateException("Cloud asset cannot be read", unavailable);
        }
    }

    /** Schedule work on the client thread without relying on OptiFine tick hooks. */
    public CaptureScenes() {
        Thread scheduler = new Thread(() -> {
            while (true) {
                try {
                    Thread.sleep(100);
                    Minecraft.getInstance().execute(() -> {
                        if (++scheduledTicks % 5 == 0) {
                            onTick();
                        }
                        onRender();
                    });
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }, "SimpleShader scene scheduler");
        scheduler.setDaemon(true);
        scheduler.start();
        System.out.println("SIMPLE_PREVIEW helper loaded");
    }

    /** Fill a small test volume and notify the normal client mesh builder. */
    private static void fill(ServerLevel level, int x1, int y1, int z1,
                             int x2, int y2, int z2, Block block) {
        BlockState state = block.defaultBlockState();
        if (block instanceof LeavesBlock) {
            state = state.setValue(LeavesBlock.PERSISTENT, true);
        }
        for (int x = x1; x <= x2; x++) {
            for (int y = y1; y <= y2; y++) {
                for (int z = z1; z <= z2; z++) {
                    level.setBlock(new BlockPos(x, y, z), state, 2);
                }
            }
        }
    }

    /** Place both halves through the actual block-state properties. */
    private static void tallPlant(ServerLevel level, int x, int y, int z, Block block) {
        BlockState lower = block.defaultBlockState()
            .setValue(BlockStateProperties.DOUBLE_BLOCK_HALF, DoubleBlockHalf.LOWER);
        BlockState upper = lower.setValue(BlockStateProperties.DOUBLE_BLOCK_HALF, DoubleBlockHalf.UPPER);
        level.setBlock(new BlockPos(x, y, z), lower, 2);
        level.setBlock(new BlockPos(x, y + 1, z), upper, 2);
    }

    /** A real block-entity bed next to neutral terrain reveals unlit model paths. */
    private static void bed(ServerLevel level, int x, int y, int z) {
        BlockState state = Blocks.WHITE_BED.defaultBlockState()
            .setValue(BlockStateProperties.HORIZONTAL_FACING, Direction.NORTH);
        level.setBlock(new BlockPos(x, y, z),
            state.setValue(BlockStateProperties.BED_PART, BedPart.FOOT), 2);
        level.setBlock(new BlockPos(x, y, z - 1),
            state.setValue(BlockStateProperties.BED_PART, BedPart.HEAD), 2);
    }

    /** Teleport through the server so the camera cannot be corrected back. */
    private static void camera(MinecraftServer server, String coordinates) {
        String[] values = coordinates.split(" ");
        for (ServerPlayer player : server.getPlayerList().getPlayers()) {
            player.setGameMode(GameType.SPECTATOR);
            player.teleportTo(server.overworld(), Double.parseDouble(values[0]),
                Double.parseDouble(values[1]), Double.parseDouble(values[2]),
                Set.of(), Float.parseFloat(values[3]), Float.parseFloat(values[4]), true);
        }
    }

    /** Exercise the loot path that crashed on leaf decay, without creating drops. */
    private static void verifyLootLoading(ServerLevel level) {
        BlockPos position = new BlockPos(-94, 82, 54);
        int items = 0;
        for (int iteration = 0; iteration < 32; iteration++) {
            for (Block block : new Block[] {Blocks.OAK_LEAVES, Blocks.STONE, Blocks.TORCH}) {
                items += Block.getDrops(block.defaultBlockState(), level, position, null).size();
            }
        }
        System.out.println("SIMPLE_PREVIEW loot checks=96 items=" + items);
    }

    /** Prepare geometry on the server thread without touching the source save. */
    private void prepare(MinecraftServer server) {
        ServerLevel level = server.overworld();
        // Capture can fall back to a vanilla connection. Preserve the copied world's configs.
        ModConfig config = ConfigTracker.INSTANCE.fileMap().get("forge-server.toml");
        if (config != null && config.getConfigData() != null
            && !(config.getConfigData() instanceof CommentedFileConfig)) {
            ConfigTracker.INSTANCE.loadConfigs(ModConfig.Type.SERVER,
                server.getWorldPath(LevelResource.ROOT).resolve("serverconfig"));
            System.out.println("SIMPLE_PREVIEW restored local file configs");
        }
        verifyLootLoading(level);
        level.getGameRules().set(GameRules.ADVANCE_TIME, false, server);
        level.setWeatherParameters(200000, 0, false, false);
        // Shallow sunlit pool: a six-block water path exposes animated caustic detail.
        fill(level, 139, 73, -16, 161, 90, 16, Blocks.AIR);
        fill(level, 139, 73, -16, 161, 74, 16, Blocks.STONE);
        fill(level, 139, 75, -16, 139, 80, 16, Blocks.STONE);
        fill(level, 161, 75, -16, 161, 80, 16, Blocks.STONE);
        fill(level, 139, 75, -16, 161, 80, -16, Blocks.STONE);
        fill(level, 139, 75, 16, 161, 80, 16, Blocks.STONE);
        fill(level, 140, 75, -15, 160, 80, 15, Blocks.WATER);
        // No skylight or emitters; material and orientation must remain readable.
        fill(level, -133, 78, 38, -115, 88, 62, Blocks.STONE);
        fill(level, -132, 81, 39, -116, 85, 61, Blocks.AIR);
        fill(level, -128, 81, 48, -127, 84, 49, Blocks.QUARTZ_BLOCK);
        // 连续岩坡作林地背景，避免光束与白色天空混在一起；日照从侧面进入林间。
        fill(level, -285, 78, 20, -195, 105, 95, Blocks.AIR);
        fill(level, -285, 78, 20, -195, 80, 95, Blocks.GRASS_BLOCK);
        fill(level, -285, 81, 28, -195, 95, 40, Blocks.STONE);
        fill(level, -285, 81, 22, -195, 100, 28, Blocks.STONE);
        for (int x : new int[] {-268, -252, -236, -220, -204}) {
            for (int z : new int[] {50, 64, 78}) {
                fill(level, x, 81, z, x, 88, z, Blocks.OAK_LOG);
                fill(level, x - 3, 87, z - 3, x + 3, 89, z + 3, Blocks.OAK_LEAVES);
                fill(level, x - 2, 90, z - 2, x + 2, 91, z + 2, Blocks.OAK_LEAVES);
            }
        }
        // Opaque and alpha-tested silhouettes share a horizon-facing twilight fixture.
        fill(level, -195, 78, -16, -145, 106, 16, Blocks.AIR);
        fill(level, -195, 78, -16, -145, 80, 16, Blocks.GRASS_BLOCK);
        fill(level, -172, 81, -7, -170, 101, -5, Blocks.QUARTZ_BLOCK);
        fill(level, -172, 81, 3, -172, 89, 3, Blocks.OAK_LOG);
        fill(level, -175, 87, 0, -168, 94, 6, Blocks.OAK_LEAVES);
        fill(level, -179, 81, 9, -168, 86, 14, Blocks.STONE);
        fill(level, -177, 87, 10, -170, 89, 13, Blocks.STONE);
        // A sealed colour-separated room exposes indirect colour and two light directions.
        fill(level, -103, 78, 38, -86, 87, 58, Blocks.STONE);
        fill(level, -102, 81, 39, -87, 85, 57, Blocks.AIR);
        fill(level, -102, 80, 39, -87, 80, 57, Blocks.QUARTZ_BLOCK);
        fill(level, -102, 81, 39, -102, 85, 57, Blocks.RED_CONCRETE);
        fill(level, -87, 81, 39, -87, 85, 57, Blocks.BLUE_CONCRETE);
        fill(level, -96, 81, 48, -96, 84, 48, Blocks.QUARTZ_BLOCK);
        level.setBlock(new BlockPos(-98, 81, 46), Blocks.TORCH.defaultBlockState(), 2);
        // Symmetric neutral floor, a pillar shadow, and a switchable torch in that shadow.
        fill(level, -80, 78, 38, -60, 95, 65, Blocks.AIR);
        fill(level, -80, 78, 38, -60, 79, 65, Blocks.STONE);
        fill(level, -80, 80, 38, -60, 80, 65, Blocks.QUARTZ_BLOCK);
        fill(level, -70, 81, 50, -70, 84, 50, Blocks.STONE);
        bed(level, -75, 81, 50);
        fill(level, -73, 81, 49, -73, 81, 50, Blocks.WHITE_WOOL);
        level.setBlock(new BlockPos(-77, 81, 49), Blocks.CHEST.defaultBlockState(), 2);
        fill(level, -20, 78, -20, 20, 90, 20, Blocks.AIR);
        fill(level, -20, 78, -20, 20, 79, 20, Blocks.STONE);
        fill(level, -20, 80, -20, 20, 80, 20, Blocks.GRASS_BLOCK);
        fill(level, 3, 78, -5, 13, 80, 5, Blocks.WATER);
        // Sand must have support; otherwise it falls and exposes the original terrain.
        fill(level, 3, 76, -5, 13, 76, 5, Blocks.STONE);
        fill(level, 3, 77, -5, 13, 77, 5, Blocks.SAND);
        // One-, two- and three-block depths expose apparent depth and shallow clarity.
        fill(level, 3, 78, -5, 7, 79, 5, Blocks.SANDSTONE);
        fill(level, 8, 78, -5, 10, 78, 5, Blocks.SANDSTONE);
        fill(level, -8, 81, -3, -6, 86, -1, Blocks.STONE);
        fill(level, -3, 81, -8, -1, 84, -6, Blocks.OAK_PLANKS);
        fill(level, -13, 81, -10, -13, 85, -10, Blocks.OAK_LOG);
        fill(level, -15, 85, -12, -11, 87, -8, Blocks.OAK_LEAVES);
        // Colour-separated columns make reflected silhouettes and wave distortion observable.
        fill(level, 3, 81, -10, 5, 89, -8, Blocks.RED_CONCRETE);
        fill(level, 7, 81, -10, 9, 86, -8, Blocks.QUARTZ_BLOCK);
        fill(level, 11, 81, -10, 13, 91, -8, Blocks.BLUE_CONCRETE);
        // A fully sealed chamber has zero skylight; only the lit cases receive torches.
        fill(level, 40, 76, -15, 61, 90, 11, Blocks.STONE);
        fill(level, 41, 81, -14, 60, 89, 10, Blocks.AIR);
        fill(level, 44, 78, -10, 57, 80, 5, Blocks.WATER);
        fill(level, 44, 77, -10, 57, 77, 5, Blocks.SAND);
        fill(level, 43, 81, -13, 45, 86, -11, Blocks.RED_CONCRETE);
        fill(level, 55, 81, -13, 57, 86, -11, Blocks.QUARTZ_BLOCK);
        // A neutral floor under leaves isolates solar shadow and local light changes.
        fill(level, -43, 79, -13, -21, 89, 9, Blocks.AIR);
        fill(level, -43, 79, -13, -21, 79, 9, Blocks.STONE);
        fill(level, -43, 80, -13, -21, 80, 9, Blocks.QUARTZ_BLOCK);
        fill(level, -40, 86, -10, -24, 87, 5, Blocks.OAK_LEAVES);
        fill(level, -34, 86, -3, -29, 86, 2, Blocks.STONE);
        fill(level, -40, 81, -8, -40, 85, -8, Blocks.OAK_LOG);
        fill(level, -24, 81, -8, -24, 85, -8, Blocks.OAK_LOG);
        // Repeated silhouettes expose fog changes at three known distances.
        fill(level, -14, 78, -26, -10, 91, -22, Blocks.STONE);
        fill(level, -2, 78, -50, 2, 91, -46, Blocks.STONE);
        fill(level, 10, 78, -74, 14, 91, -70, Blocks.STONE);
        // Tall geometry verifies that foreground objects occlude cloud faces.
        fill(level, -18, 81, -15, -16, 208, -13, Blocks.STONE);
        level.setBlock(new BlockPos(-4, 81, 4), Blocks.TORCH.defaultBlockState(), 2);
        level.setBlock(new BlockPos(-2, 81, 4), Blocks.GLOWSTONE.defaultBlockState(), 2);
        // Independent plant groups expose short roots, double-height seams and leaf volume.
        fill(level, -12, 78, 38, 12, 89, 65, Blocks.AIR);
        fill(level, -12, 78, 38, 12, 79, 65, Blocks.STONE);
        fill(level, -12, 80, 38, 12, 80, 65, Blocks.QUARTZ_BLOCK);
        fill(level, -10, 80, 40, -4, 80, 48, Blocks.GRASS_BLOCK);
        fill(level, -2, 80, 40, 3, 80, 48, Blocks.GRASS_BLOCK);
        fill(level, 5, 80, 40, 10, 80, 48, Blocks.GRASS_BLOCK);
        for (int x = -9; x <= -5; x += 2) {
            for (int z = 41; z <= 47; z += 2) {
                level.setBlock(new BlockPos(x, 81, z), Blocks.SHORT_GRASS.defaultBlockState(), 2);
            }
        }
        for (int z = 41; z <= 47; z += 2) {
            level.setBlock(new BlockPos(-1, 81, z), Blocks.FERN.defaultBlockState(), 2);
            level.setBlock(new BlockPos(2, 81, z), Blocks.POPPY.defaultBlockState(), 2);
            tallPlant(level, 6, 81, z, Blocks.TALL_GRASS);
            tallPlant(level, 9, 81, z, Blocks.ROSE_BUSH);
        }
        // Mature crops retain their vanilla model height and rooted attachment.
        for (int x = -8; x <= -3; x++) {
            for (int z = 51; z <= 56; z++) {
                BlockState soil = Blocks.FARMLAND.defaultBlockState()
                    .setValue(BlockStateProperties.MOISTURE, 7);
                level.setBlock(new BlockPos(x, 80, z), soil, 2);
                Block crop = x < -5 ? Blocks.WHEAT : Blocks.CARROTS;
                level.setBlock(new BlockPos(x, 81, z), crop.defaultBlockState()
                    .setValue(BlockStateProperties.AGE_7, 7), 2);
            }
        }
        fill(level, -2, 80, 50, -2, 80, 57, Blocks.WATER);
        fill(level, 5, 80, 51, 10, 80, 56, Blocks.GRASS_BLOCK);
        for (int x = 6; x <= 9; x += 3) {
            tallPlant(level, x, 81, 52, Blocks.SUNFLOWER);
            tallPlant(level, x, 81, 55, Blocks.LARGE_FERN);
        }
        fill(level, -7, 81, 60, -7, 84, 60, Blocks.OAK_LOG);
        fill(level, -10, 84, 58, -4, 85, 63, Blocks.OAK_LEAVES);
        fill(level, 7, 81, 60, 7, 84, 60, Blocks.OAK_LOG);
        fill(level, 4, 84, 58, 10, 85, 63, Blocks.CHERRY_LEAVES);
        // A sealed-sided deep tank gives known surface height and immersion depths.
        fill(level, 89, 50, -21, 113, 96, 21, Blocks.AIR);
        fill(level, 89, 50, -21, 113, 52, 21, Blocks.STONE);
        fill(level, 89, 53, -21, 89, 80, 21, Blocks.STONE);
        fill(level, 113, 53, -21, 113, 80, 21, Blocks.STONE);
        fill(level, 89, 53, -21, 113, 80, -21, Blocks.STONE);
        fill(level, 89, 53, 21, 113, 80, 21, Blocks.STONE);
        fill(level, 90, 53, -20, 112, 80, 20, Blocks.WATER);
        // A broken canopy casts moving-angle columns into the water volume.
        fill(level, 94, 84, -10, 108, 84, 6, Blocks.OAK_LEAVES);
        fill(level, 97, 84, -10, 98, 84, 6, Blocks.AIR);
        fill(level, 104, 84, -10, 105, 84, 6, Blocks.AIR);
        fill(level, 98, 53, -12, 100, 64, -10, Blocks.QUARTZ_BLOCK);
        fill(level, 104, 53, -12, 106, 64, -10, Blocks.RED_CONCRETE);
        fill(level, 105, 53, 2, 108, 55, 4, Blocks.STONE);
        fill(level, 105, 56, 2, 108, 56, 4, Blocks.STONE);
        // Shore objects above the known surface expose refraction and the Snell window.
        fill(level, 94, 80, -27, 96, 94, -25, Blocks.RED_CONCRETE);
        fill(level, 100, 80, -27, 102, 91, -25, Blocks.QUARTZ_BLOCK);
        fill(level, 106, 80, -27, 108, 96, -25, Blocks.BLUE_CONCRETE);
        // A column crossing the interface tests foreground occlusion and refracted continuity.
        fill(level, 99, 73, 3, 100, 86, 4, Blocks.QUARTZ_BLOCK);
        camera(server, "0 84 17 180 12");
        System.out.println("SIMPLE_PREVIEW geometry ready");
        commandsReady.set(true);
    }

    /** Inspect the real loader's water controls without opening or changing its UI. */
    private static void inspectShaderOptions(String page) {
        try {
            Class<?> shaders = Class.forName("net.optifine.shaders.Shaders");
            Object[] options = (Object[]) shaders.getMethod("getShaderPackOptions", String.class)
                .invoke(null, page);
            for (Object option : options) {
                if (option == null) {
                    continue;
                }
                Class<?> type = option.getClass();
                String name = (String) type.getMethod("getName").invoke(option);
                String value = (String) type.getMethod("getValue").invoke(option);
                String[] values = (String[]) type.getMethod("getValues").invoke(option);
                boolean slider = (Boolean) shaders.getMethod("isShaderPackOptionSlider", String.class)
                    .invoke(null, name);
                System.out.println("SIMPLE_PREVIEW " + page + " option " + name + "=" + value
                    + " values=" + java.util.Arrays.toString(values) + " slider=" + slider);
            }
            System.out.println("SIMPLE_PREVIEW oldLighting="
                + shaders.getMethod("isOldLighting").invoke(null) + " separateAo="
                + shaders.getMethod("isSeparateAo").invoke(null));
        } catch (ReflectiveOperationException unavailable) {
            throw new IllegalStateException(page + " controls inspection failed", unavailable);
        }
    }

    /** Advance fixed camera/time cases after meshes and lighting have warmed up. */
    private void onTick() {
        Minecraft client = Minecraft.getInstance();
        if (client.level == null || client.player == null) {
            return;
        }
        // Reapply the requested viewport after macOS places a large new window.
        if (loadedTicks == 0) {
            GLFW.glfwSetWindowPos(client.getWindow().handle(), 0, 32);
            GLFW.glfwSetWindowSize(client.getWindow().handle(),
                Integer.getInteger("simpleshader.preview.width", 960),
                Integer.getInteger("simpleshader.preview.height", 540));
        }
        client.options.pauseOnLostFocus = false;
        client.mouseHandler.releaseMouse();
        if (selectedCamera != null) {
            String[] pose = selectedCamera.split(" ");
            float yaw = Float.parseFloat(pose[3]);
            float pitch = Float.parseFloat(pose[4]);
            client.player.setYRot(yaw);
            client.player.setXRot(pitch);
            client.player.yRotO = yaw;
            client.player.xRotO = pitch;
            client.player.setDeltaMovement(0.0, 0.0, 0.0);
        }
        if (scene >= 0 && !rebuilt && System.nanoTime() - sceneStart > 2_000_000_000L) {
            client.levelRenderer.allChanged();
            rebuilt = true;
        }
        client.options.hideGui = true;
        client.options.cloudStatus().set(CloudStatus.FANCY);
        loadedTicks += 10;
        if (loadedTicks == 20) {
            MinecraftServer server = client.getSingleplayerServer();
            if (server != null) {
                server.execute(() -> prepare(server));
            }
        }
        if (loadedTicks == 240) {
            inspectShaderOptions("WATER");
            inspectShaderOptions("VEGETATION");
            inspectShaderOptions("LIGHTING");
            inspectShaderOptions("LOCAL_LIGHTS");
            inspectShaderOptions("GI");
            inspectShaderOptions("WORLD");
            inspectShaderOptions("SKY");
            inspectShaderOptions("CLOUDS");
            inspectShaderOptions("POST");
        }
        if (!commandsReady.get() || loadedTicks < 240) {
            return;
        }
        client.setScreen(null);
        if (scene == -1 || (requested && !continuesSequence()
            && System.nanoTime() - sceneStart > 8_000_000_000L)) {
            scene++;
            requested = false;
            rebuilt = false;
            sceneStart = System.nanoTime();
            if (scene < SCENES.length) {
                String[] selected = SCENES[scene];
                client.options.fov().set(selected[0].startsWith("sky_moon") ? 30 : 70);
                MinecraftServer server = client.getSingleplayerServer();
                server.execute(() -> {
                    ServerLevel level = server.overworld();
                    level.setDayTime(Long.parseLong(selected[1]));
                    if (selected[0].startsWith("lens_sun_")) {
                        Block barrier = selected[0].equals("lens_sun_blocked")
                            ? Blocks.STONE : Blocks.AIR;
                        fill(level, 30, 95, 0, 32, 118, 34, barrier);
                    }
                    if (selected[0].equals("lighting_gi_two_lights")) {
                        level.setBlock(new BlockPos(-90, 81, 50), Blocks.TORCH.defaultBlockState(), 2);
                    }
                    if (selected[0].startsWith("lighting_")) {
                        Block light = selected[0].endsWith("_lit") ? Blocks.TORCH : Blocks.AIR;
                        level.setBlock(new BlockPos(-73, 81, 52), light.defaultBlockState(), 2);
                    }
                    if (selected[0].equals("water_cave_lit")) {
                        level.setBlock(new BlockPos(42, 81, -8), Blocks.TORCH.defaultBlockState(), 2);
                        level.setBlock(new BlockPos(59, 81, -8), Blocks.TORCH.defaultBlockState(), 2);
                        level.setBlock(new BlockPos(42, 81, 4), Blocks.TORCH.defaultBlockState(), 2);
                        level.setBlock(new BlockPos(59, 81, 4), Blocks.TORCH.defaultBlockState(), 2);
                    }
                    if (selected[0].equals("underwater_magma_lit")) {
                        fill(level, 105, 56, 2, 108, 56, 4, Blocks.MAGMA_BLOCK);
                    }
                    if (selected[0].equals("local_shadow_lit")) {
                        level.setBlock(new BlockPos(-32, 81, 0), Blocks.TORCH.defaultBlockState(), 2);
                        level.setBlock(new BlockPos(-26, 81, 0), Blocks.GLOWSTONE.defaultBlockState(), 2);
                    }
                    if (selected[0].equals("water_glass")) {
                        fill(level, 7, 81, -2, 9, 85, -2, Blocks.RED_STAINED_GLASS);
                    }
                    String position = selected[2];
                    if (selected[0].equals("cloud_below") || selected[0].equals("cloud_inside")
                        || selected[0].equals("cloud_above")) {
                        position = cloudCamera(selected[0]);
                    }
                    selectedCamera = position;
                    camera(server, position);
                });
                client.setScreen(null);
                System.out.println("SIMPLE_PREVIEW scene " + selected[0]);
            } else {
                finishStart = System.nanoTime();
            }
        }
        if (scene >= SCENES.length && System.nanoTime() - finishStart > 2_000_000_000L) {
            System.out.println("SIMPLE_PREVIEW complete");
            client.stop();
        }
    }

    /** Consecutive fixed-camera samples reuse warmed geometry and the same solar time. */
    private boolean continuesSequence() {
        if (scene < 0 || scene + 1 >= SCENES.length) {
            return false;
        }
        String name = SCENES[scene][0];
        int marker = name.lastIndexOf("_sequence_");
        return marker >= 0 && SCENES[scene + 1][0].startsWith(name.substring(0, marker + 10))
            && SCENES[scene][1].equals(SCENES[scene + 1][1])
            && SCENES[scene][2].equals(SCENES[scene + 1][2]);
    }

    /** Ask the actual client to read its final render target for each baseline. */
    private void onRender() {
        if (scene < 0 || scene >= SCENES.length) {
            return;
        }
        if (requested) {
            if (!continuesSequence() || System.nanoTime() - lastCapture < 180_000_000L) {
                return;
            }
            scene++;
            requested = false;
            System.out.println("SIMPLE_PREVIEW scene " + SCENES[scene][0]);
        }
        long elapsed = System.nanoTime() - sceneStart;
        if (elapsed < 12_000_000_000L) {
            return;
        }
        Minecraft client = Minecraft.getInstance();
        String name = SCENES[scene][0];
        boolean forest = name.startsWith("sunshafts_") && !name.equals("sunshafts_room");
        boolean ready = client.levelRenderer.getSectionRenderDispatcher().getCompileQueueSize() == 0
            && (!forest || client.levelRenderer.countRenderedSections() >= 24);
        if (!ready) {
            if (elapsed > 45_000_000_000L) {
                client.stop();
                throw new IllegalStateException("Scene sections did not finish loading: " + name);
            }
            return;
        }
        requested = true;
        lastCapture = System.nanoTime();
        System.out.println("SIMPLE_PREVIEW sections " + name + "="
            + client.levelRenderer.getSectionStatistics() + " backdrop="
            + client.level.getBlockState(new BlockPos(-220, 88, 40)));
        System.out.println("SIMPLE_PREVIEW fps " + name + "=" + client.getFps());
        Screenshot.grab(new File(client.gameDirectory.getAbsolutePath()),
            name + ".png", client.getMainRenderTarget(), 1,
            message -> System.out.println("SIMPLE_PREVIEW screenshot " + name));
    }
}
