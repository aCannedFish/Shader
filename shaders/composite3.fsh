#version 120
/* composite3.fsh: extract bloom after all sky, cloud and water compositing. */
/* RENDERTARGETS: 3 */
#include "settings.glsl"
#include "lib/uniforms.glsl"
#include "lib/common.glsl"
uniform sampler2D colortex0;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    vec3 color = texture2D(colortex0, uv).rgb;
#if ENABLE_BLOOM == 0
    gl_FragData[0] = vec4(0.0, 0.0, 0.0, 1.0);
#else
    float brightness = luma(color);
    float weight = max(brightness - BLOOM_THRESHOLD, 0.0) / max(brightness, EPSILON);
    gl_FragData[0] = vec4(color * weight, 1.0);
#endif
}
