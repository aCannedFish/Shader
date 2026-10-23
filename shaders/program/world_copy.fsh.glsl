/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
layout(location=0) out vec4 result;

// Synchronize untouched atlas regions once before the partial producers. Each
// later region is produced twice to keep both ping-pong banks coherent.
void main() {
    result = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0);
}
