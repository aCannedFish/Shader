#version 120
/* 半分辨率水下光柱。复用云附件，RGB 保存散射，alpha 保存路径深度；
 * 首个纹素的 alpha 保留每帧一次的入水深度估计。
 */
/* RENDERTARGETS: 4 */
#include "lib/water_effects.glsl"
uniform sampler2D colortex4;
uniform sampler2D colortex5;
uniform sampler2D depthtex1;

void main() {
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
    vec2 uv = gl_FragCoord.xy / size;
    if (isEyeInWater != 1) {
        gl_FragData[0] = texture2D(colortex4, uv * size / vec2(viewWidth, viewHeight));
        return;
    }
    float eyeDepth = texture2D(colortex4, vec2(0.5) / vec2(viewWidth, viewHeight)).r;
    float opaqueDepth = texture2D(depthtex1, uv).r;
    float surfaceDepth = texture2D(colortex5, uv).a;
    float path = underwaterVisiblePath(uv, opaqueDepth, surfaceDepth, eyeDepth);
    vec3 shafts = integrateWaterShafts(uv, path, eyeDepth);
    float metadata = min(path, 48.0);
    if (gl_FragCoord.x < 1.0 && gl_FragCoord.y < 1.0) {
        metadata = eyeDepth;
    }
    gl_FragData[0] = vec4(shafts, metadata);
}
