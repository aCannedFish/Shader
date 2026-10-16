#version 120
/* Supply the sky before translucent blending, and preserve opaque HDR for water. */
/* RENDERTARGETS: 6,0 */
#include "lib/sky_background.glsl"
uniform sampler2D colortex0;
uniform sampler2D depthtex0;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    float depth = texture2D(depthtex0, uv).r;
    vec3 color = fillSkyBackground(texture2D(colortex0, uv).rgb, uv, depth);
    // Glass writes depth. Filling its background afterwards would leave black
    // behind every nonzero-alpha texel, even though clear glass holes look fine.
    gl_FragData[1] = vec4(color, 1.0);
    vec3 opaque = depth < 0.999999
        ? correctSkyFog(color, uv, length(screenToView(uv, depth))) : color;
    gl_FragData[0] = vec4(opaque, 1.0);
}
