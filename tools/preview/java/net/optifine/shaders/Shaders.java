package net.optifine.shaders;

/**
 * Program identity bridge used by the unmodified OptiFine remapper.
 * The three identities select its basic/sky compatibility rules without
 * initializing Minecraft, an OpenGL context, or the full Shaders host class.
 */
public final class Shaders {
    public static final Program ProgramBasic =
        new Program(1, "gbuffers_basic", ProgramStage.GBUFFERS, false);
    public static final Program ProgramSkyBasic =
        new Program(2, "gbuffers_skybasic", ProgramStage.GBUFFERS, false);
    public static final Program ProgramSkyTextured =
        new Program(3, "gbuffers_skytextured", ProgramStage.GBUFFERS, false);

    private Shaders() {
    }
}
