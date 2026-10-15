#version 120
/* 场景合成后的水平泛光过滤；首个 alpha 纹素保存每帧一次的太阳可见度。 */
/* RENDERTARGETS: 3 */
#include "lib/bloom.glsl"
#include "lib/lens_optics.glsl"
uniform sampler2D colortex0;
uniform sampler2D depthtex0;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    float visibility = 0.0;
    if (gl_FragCoord.x < 1.0 && gl_FragCoord.y < 1.0) {
        visibility = lensSunVisibility(colortex0, depthtex0);
    }
    vec3 bloom = filterBloom(colortex0, uv, vec2(1.0, 0.0), true);
    gl_FragData[0] = vec4(bloom, visibility);
}
