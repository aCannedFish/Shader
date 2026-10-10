package local.simpleshader.lighting;

import java.nio.ByteBuffer;
import org.lwjgl.BufferUtils;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL13;
import org.lwjgl.opengl.GL15;
import org.lwjgl.opengl.GL20;
import org.lwjgl.opengl.GL21;
import org.lwjgl.opengl.GL30;

/** Restore the actual OpenGL state without changing Minecraft's state caches. */
final class GlState implements AutoCloseable {
    private final int program = GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM);
    private final int drawFramebuffer = GL11.glGetInteger(GL30.GL_DRAW_FRAMEBUFFER_BINDING);
    private final int readFramebuffer = GL11.glGetInteger(GL30.GL_READ_FRAMEBUFFER_BINDING);
    private final int vertexArray = GL11.glGetInteger(GL30.GL_VERTEX_ARRAY_BINDING);
    private final int arrayBuffer = GL11.glGetInteger(GL15.GL_ARRAY_BUFFER_BINDING);
    private final int unpackBuffer = GL11.glGetInteger(GL21.GL_PIXEL_UNPACK_BUFFER_BINDING);
    private final int activeTexture = GL11.glGetInteger(GL13.GL_ACTIVE_TEXTURE);
    private final int[] viewport = new int[4];
    private final int[] scissor = new int[4];
    private final int[] textures = new int[8];
    private final int[] unpack = new int[4];
    private final boolean[] blend = new boolean[8];
    private final byte[][] masks = new byte[8][4];
    private final boolean depth = GL11.glIsEnabled(GL11.GL_DEPTH_TEST);
    private final boolean cull = GL11.glIsEnabled(GL11.GL_CULL_FACE);
    private final boolean scissorEnabled = GL11.glIsEnabled(GL11.GL_SCISSOR_TEST);
    private final boolean depthMask = GL11.glGetBoolean(GL11.GL_DEPTH_WRITEMASK);
    private final int depthFunction = GL11.glGetInteger(GL11.GL_DEPTH_FUNC);
    private final float[] clearColor = new float[4];
    private final double clearDepth = GL11.glGetDouble(GL11.GL_DEPTH_CLEAR_VALUE);

    GlState() {
        GL11.glGetIntegerv(GL11.GL_VIEWPORT, viewport);
        GL11.glGetIntegerv(GL11.GL_SCISSOR_BOX, scissor);
        GL11.glGetFloatv(GL11.GL_COLOR_CLEAR_VALUE, clearColor);
        int[] keys = {GL11.GL_UNPACK_ALIGNMENT, GL11.GL_UNPACK_ROW_LENGTH,
                      GL11.GL_UNPACK_SKIP_ROWS, GL11.GL_UNPACK_SKIP_PIXELS};
        for (int index = 0; index < 4; index++) {
            unpack[index] = GL11.glGetInteger(keys[index]);
            GL11.glPixelStorei(keys[index], index == 0 ? 4 : 0);
        }
        GL15.glBindBuffer(GL21.GL_PIXEL_UNPACK_BUFFER, 0);
        ByteBuffer mask = BufferUtils.createByteBuffer(4);
        for (int index = 0; index < 8; index++) {
            GL13.glActiveTexture(GL13.GL_TEXTURE0 + index);
            textures[index] = GL11.glGetInteger(GL11.GL_TEXTURE_BINDING_2D);
            blend[index] = GL30.glIsEnabledi(GL11.GL_BLEND, index);
            mask.clear();
            GL30.glGetBooleani_v(GL11.GL_COLOR_WRITEMASK, index, mask);
            for (int component = 0; component < 4; component++) {
                masks[index][component] = mask.get(component);
            }
        }
        GL11.glDisable(GL11.GL_BLEND);
        GL11.glDisable(GL11.GL_CULL_FACE);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL11.glColorMask(true, true, true, true);
        GL13.glActiveTexture(GL13.GL_TEXTURE0);
    }

    @Override
    public void close() {
        GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER, drawFramebuffer);
        GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, readFramebuffer);
        GL30.glBindVertexArray(vertexArray);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, arrayBuffer);
        GL15.glBindBuffer(GL21.GL_PIXEL_UNPACK_BUFFER, unpackBuffer);
        GL20.glUseProgram(program);
        GL11.glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
        GL11.glScissor(scissor[0], scissor[1], scissor[2], scissor[3]);
        enable(GL11.GL_DEPTH_TEST, depth);
        enable(GL11.GL_CULL_FACE, cull);
        enable(GL11.GL_SCISSOR_TEST, scissorEnabled);
        GL11.glDepthMask(depthMask);
        GL11.glDepthFunc(depthFunction);
        GL11.glClearDepth(clearDepth);
        GL11.glClearColor(clearColor[0], clearColor[1], clearColor[2], clearColor[3]);
        int[] keys = {GL11.GL_UNPACK_ALIGNMENT, GL11.GL_UNPACK_ROW_LENGTH,
                      GL11.GL_UNPACK_SKIP_ROWS, GL11.GL_UNPACK_SKIP_PIXELS};
        for (int index = 0; index < 4; index++) {
            GL11.glPixelStorei(keys[index], unpack[index]);
        }
        for (int index = 0; index < 8; index++) {
            GL13.glActiveTexture(GL13.GL_TEXTURE0 + index);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, textures[index]);
            if (blend[index]) {
                GL30.glEnablei(GL11.GL_BLEND, index);
            } else {
                GL30.glDisablei(GL11.GL_BLEND, index);
            }
            GL30.glColorMaski(index, masks[index][0] != 0, masks[index][1] != 0,
                             masks[index][2] != 0, masks[index][3] != 0);
        }
        GL13.glActiveTexture(activeTexture);
    }

    private static void enable(int capability, boolean enabled) {
        if (enabled) {
            GL11.glEnable(capability);
        } else {
            GL11.glDisable(capability);
        }
    }
}
