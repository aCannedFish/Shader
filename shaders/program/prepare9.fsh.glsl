/* RENDERTARGETS: 12 */
uniform sampler2D colortex12;
layout(location=0) out vec4 result;
void main() {
    result = texelFetch(colortex12, ivec2(gl_FragCoord.xy), 0);
}
