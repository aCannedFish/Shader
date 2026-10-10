#version 120
/* deferred1.fsh: preserve opaque HDR colour with the same sky and aerial fog. */
/* RENDERTARGETS: 6 */
#include "/lib/sky_background.glsl"
uniform sampler2D colortex0;
uniform sampler2D depthtex0;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    float depth = texture2D(depthtex0, uv).r;
    vec3 color = fillSkyBackground(texture2D(colortex0, uv).rgb, uv, depth);
    if (depth < 0.999999) {
        color = correctSkyFog(color, uv, length(screenToView(uv, depth)));
    }
    gl_FragData[0] = vec4(color, 1.0);
}
