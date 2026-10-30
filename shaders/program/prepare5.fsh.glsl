/* RENDERTARGETS: 8,10 */
uniform sampler2D colortex8;
uniform sampler2D colortex10;
layout(location=0) out vec4 result;
layout(location=1) out vec4 candidates;
void main() {
    result = texelFetch(colortex8, ivec2(gl_FragCoord.xy), 0);
    candidates = texelFetch(colortex10, ivec2(gl_FragCoord.xy), 0);
}
