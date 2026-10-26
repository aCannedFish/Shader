import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.commons.ClassRemapper;
import org.objectweb.asm.commons.SimpleRemapper;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.VarInsnNode;

/** Test-JVM-only GPU timing hooks. No shader or world data is changed. */
public final class GpuTimings {
    public static void premain(String arguments, Instrumentation instrumentation) {
        instrumentation.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String name, Class<?> type,
                                    ProtectionDomain domain, byte[] bytes) {
                if (!name.equals("net/optifine/shaders/Shaders")) return null;
                try {
                    ClassNode target = new ClassNode();
                    new ClassReader(bytes).accept(target, 0);
                    ClassNode template = new ClassNode();
                    try (var source = GpuTimings.class.getResourceAsStream("GpuTimings$Template.class")) {
                        new ClassReader(source).accept(new ClassRemapper(template,
                            new SimpleRemapper("GpuTimings$Template", name)), 0);
                    }
                    // Merge methods into the engine class so LWJGL resolves in
                    // its existing loader, without introducing runtime helpers.
                    for (var method : target.methods) {
                        InsnList hook = new InsnList();
                        if (method.name.equals("useProgram") || method.name.equals("useComputeProgram")) {
                            String program = method.name.equals("useProgram") ? "Program" : "ComputeProgram";
                            // OptiFine redirects terrain program requests to
                            // shadow while isShadowPass is set. Label the
                            // selected program after that redirect and flush.
                            for (var instruction : method.instructions.toArray()) {
                                if (instruction.getOpcode() != Opcodes.RETURN) continue;
                                InsnList boundary = new InsnList();
                                if (program.equals("Program")) {
                                    boundary.add(new FieldInsnNode(Opcodes.GETSTATIC, name,
                                        "activeProgram", "Lnet/optifine/shaders/Program;"));
                                } else {
                                    boundary.add(new VarInsnNode(Opcodes.ALOAD, 0));
                                }
                                boundary.add(new MethodInsnNode(Opcodes.INVOKEVIRTUAL,
                                    "net/optifine/shaders/" + program, "getName", "()Ljava/lang/String;", false));
                                boundary.add(new MethodInsnNode(Opcodes.INVOKESTATIC, name,
                                    "codexGpuBoundary", "(Ljava/lang/String;)V", false));
                                method.instructions.insertBefore(instruction, boundary);
                            }
                        } else if (method.name.equals("beginRender")) {
                            hook.add(new MethodInsnNode(Opcodes.INVOKESTATIC, name,
                                "codexGpuBegin", "()V", false));
                        } else if (method.name.equals("endRender")) {
                            // Measure through endRender's final GPU commands.
                            for (var instruction : method.instructions.toArray()) {
                                if (instruction.getOpcode() == Opcodes.RETURN) {
                                    InsnList end = new InsnList();
                                    end.add(new MethodInsnNode(Opcodes.INVOKESTATIC, name,
                                        "codexGpuEnd", "()V", false));
                                    method.instructions.insertBefore(instruction, end);
                                }
                            }
                        }
                        method.instructions.insert(hook);
                    }
                    target.fields.addAll(template.fields);
                    for (var method : template.methods) {
                        if (!method.name.startsWith("<")) target.methods.add(method);
                    }
                    ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS);
                    target.accept(writer);
                    System.out.println("SIMPLE_GPU timing hooks installed");
                    return writer.toByteArray();
                } catch (Exception failure) {
                    throw new IllegalStateException("Cannot install GPU timing hooks", failure);
                }
            }
        });
    }

    /** Timestamp intervals include GPU queue gaps; CPU intervals are recorded
     * alongside them to expose submission stalls. Queries are read only when
     * available, never using glFinish or a blocking result read.
     */
    public static final class Template {
        private static java.util.ArrayList<Integer> codexGpuQueries;
        private static java.util.ArrayList<String> codexGpuLabels;
        private static java.util.ArrayList<Long> codexGpuCpu;
        private static java.util.ArrayList<Integer> codexGpuFrameIds;
        private static int codexGpuFrames;
        private static long codexGpuStart;
        private static boolean codexGpuStopped;
        private static boolean codexGpuWritten;
        private static String codexGpuLast;

        public static void codexGpuBegin() {
            codexGpuFrames++;
            codexGpuBoundary("frame.begin");
        }

        /** The scene helper owns the single warm-up/measurement clock. */
        public static void codexGpuStart() {
            codexGpuQueries = new java.util.ArrayList<>();
            codexGpuLabels = new java.util.ArrayList<>();
            codexGpuCpu = new java.util.ArrayList<>();
            codexGpuFrameIds = new java.util.ArrayList<>();
            codexGpuStart = System.nanoTime();
            System.out.println("SIMPLE_GPU measurement started");
        }

        public static void codexGpuStop() {
            codexGpuBoundary("measurement.end");
            codexGpuStopped = true;
        }

        public static void codexGpuBoundary(String label) {
            if (codexGpuStart == 0 || codexGpuStopped || label.equals(codexGpuLast)) return;
            int query = org.lwjgl.opengl.GL15.glGenQueries();
            org.lwjgl.opengl.GL33.glQueryCounter(query, org.lwjgl.opengl.GL33.GL_TIMESTAMP);
            codexGpuQueries.add(query);
            codexGpuLabels.add(label);
            codexGpuCpu.add(System.nanoTime());
            codexGpuFrameIds.add(codexGpuFrames);
            codexGpuLast = label;
        }

        public static void codexGpuEnd() {
            codexGpuBoundary("frame.outside");
            if (codexGpuStart == 0 || codexGpuWritten) return;
            if (!codexGpuStopped || codexGpuQueries.isEmpty()) return;
            int last = codexGpuQueries.get(codexGpuQueries.size() - 1);
            if (org.lwjgl.opengl.GL15.glGetQueryObjecti(last,
                org.lwjgl.opengl.GL15.GL_QUERY_RESULT_AVAILABLE) == 0) return;
            StringBuilder csv = new StringBuilder("frame,program,gpu_ms,cpu_ms\n");
            long previous = org.lwjgl.opengl.GL33.glGetQueryObjectui64(codexGpuQueries.get(0),
                org.lwjgl.opengl.GL15.GL_QUERY_RESULT);
            for (int index = 1; index < codexGpuQueries.size(); index++) {
                long timestamp = org.lwjgl.opengl.GL33.glGetQueryObjectui64(codexGpuQueries.get(index),
                    org.lwjgl.opengl.GL15.GL_QUERY_RESULT);
                csv.append(codexGpuFrameIds.get(index - 1)).append(',')
                    .append(codexGpuLabels.get(index - 1)).append(',')
                    .append((timestamp - previous) / 1.0e6).append(',')
                    .append((codexGpuCpu.get(index) - codexGpuCpu.get(index - 1)) / 1.0e6).append('\n');
                previous = timestamp;
            }
            for (int query : codexGpuQueries) org.lwjgl.opengl.GL15.glDeleteQueries(query);
            try {
                java.nio.file.Path output = java.nio.file.Path.of(
                    System.getProperty("simpleshader.preview.gpuTimings"));
                java.nio.file.Files.createDirectories(output.getParent());
                java.nio.file.Files.writeString(output, csv);
                codexGpuWritten = true;
                System.out.println("SIMPLE_GPU measurement saved " + output);
            } catch (java.io.IOException failure) {
                throw new IllegalStateException("Cannot write GPU timings", failure);
            }
        }
    }
}
