package local.simpleshader.metadata;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.ClassNode;

/** Reproduce the field access needed by Forge's build-time registry bootstrap.
 * Only an isolated classpath overlay is written. The installed game and target
 * shader instances are never modified or given this JAR.
 */
public final class PrepareRegistryApi {
    private PrepareRegistryApi() {}

    public static void main(String[] arguments) throws Exception {
        if (arguments.length != 2) throw new IllegalArgumentException("Input client JAR and output overlay required");
        List<String> classes = List.of("net/minecraft/core/IdMapper.class", "net/minecraft/core/MappedRegistry.class");
        try (ZipFile input = new ZipFile(arguments[0]);
             ZipOutputStream output = new ZipOutputStream(Files.newOutputStream(Path.of(arguments[1])))) {
            for (String name : classes) {
                ClassNode node = new ClassNode();
                new ClassReader(input.getInputStream(input.getEntry(name))).accept(node, 0);
                for (var field : node.fields) {
                    if ((field.access & Opcodes.ACC_PRIVATE) != 0) {
                        field.access = (field.access & ~Opcodes.ACC_PRIVATE) | Opcodes.ACC_PROTECTED;
                        System.out.println(name + " field access only: " + field.name);
                    }
                }
                ClassWriter writer = new ClassWriter(0);
                node.accept(writer);
                output.putNextEntry(new ZipEntry(name));
                output.write(writer.toByteArray());
                output.closeEntry();
            }
        }
    }
}
