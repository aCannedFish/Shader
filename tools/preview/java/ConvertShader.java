import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import net.optifine.shaders.Program;
import net.optifine.shaders.ProgramStage;
import net.optifine.shaders.Shaders;
import net.optifine.shaders.ShadersCompatibility;
import net.optifine.shaders.config.ShaderType;
import net.optifine.util.LineBuffer;

/**
 * Apply the installed OptiFine remapper to already-expanded shader sources.
 * Arguments are input/output pairs. This process only transforms text; it does
 * not initialize the game or perform rendering.
 */
public final class ConvertShader {
    private ConvertShader() {
    }

    private static Program program(String name) {
        if (name.equals("gbuffers_basic")) {
            return Shaders.ProgramBasic;
        }
        if (name.equals("gbuffers_skybasic")) {
            return Shaders.ProgramSkyBasic;
        }
        if (name.equals("gbuffers_skytextured")) {
            return Shaders.ProgramSkyTextured;
        }
        ProgramStage stage = ProgramStage.GBUFFERS;
        if (name.startsWith("shadowcomp")) {
            stage = ProgramStage.SHADOWCOMP;
        } else if (name.startsWith("prepare")) {
            stage = ProgramStage.PREPARE;
        } else if (name.startsWith("shadow")) {
            stage = ProgramStage.SHADOW;
        } else if (name.startsWith("deferred")) {
            stage = ProgramStage.DEFERRED;
        } else if (name.startsWith("composite") || name.equals("final")) {
            stage = ProgramStage.COMPOSITE;
        }
        return new Program(4, name, stage, false);
    }

    public static void main(String[] arguments) throws Exception {
        if (arguments.length == 0 || arguments.length % 2 != 0) {
            throw new IllegalArgumentException("Expected input/output pairs");
        }
        for (int index = 0; index < arguments.length; index += 2) {
            Path input = Path.of(arguments[index]);
            Path output = Path.of(arguments[index + 1]);
            String file = input.getFileName().toString();
            String name = file.substring(0, file.lastIndexOf('.'));
            ShaderType type = switch (file.substring(file.lastIndexOf('.'))) {
                case ".vsh" -> ShaderType.VERTEX;
                case ".gsh" -> ShaderType.GEOMETRY;
                case ".fsh" -> ShaderType.FRAGMENT;
                default -> throw new IllegalArgumentException("Unsupported shader stage: " + file);
            };
            String text = Files.readString(input, StandardCharsets.UTF_8);
            LineBuffer lines = new LineBuffer(text.split("\\R"));
            LineBuffer converted = ShadersCompatibility.remap(program(name), type, lines);
            Files.createDirectories(output.getParent());
            Files.writeString(output, converted.toString(), StandardCharsets.UTF_8);
        }
    }
}
