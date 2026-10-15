#version 120
/* 半分辨率体积场。空气中将近地面日光散射置于云层之前；水下 RGB 保存光柱，
 * alpha 保存路径深度，首个 alpha 保留每帧一次的入水深度估计。
 */
/* RENDERTARGETS: 4 */
#include "lib/water_effects.glsl"
#include "lib/air_scattering.glsl"
uniform sampler2D colortex4;
uniform sampler2D colortex5;
uniform sampler2D depthtex1;

void main() {
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
    vec2 uv = gl_FragCoord.xy / size;
    if (isEyeInWater != 1) {
        vec4 cloud = texture2D(colortex4, uv * size / vec2(viewWidth, viewHeight));
        float depth = texture2D(depthtex1, uv).r;
        float distance = depth < 0.999999 ? length(screenToView(uv, depth)) : far;
        float waterDepth = texture2D(colortex5, uv).a;
        if (waterDepth > 0.001) {
            distance = min(distance, length(waterSurfacePosition(uv, waterDepth)));
        }
        vec4 air = integrateAirScattering(uv, distance);
        // 近地面介质位于云层之前，按透射率组合，避免重复叠加亮度。
        gl_FragData[0] = vec4(air.rgb + cloud.rgb * (1.0 - air.a),
                              1.0 - (1.0 - air.a) * (1.0 - cloud.a));
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
