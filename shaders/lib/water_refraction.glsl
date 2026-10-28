/* 空气到水的折射。按 Snell 方向与水底局部平面求交，再用深度修正三次。
 * 屏幕边缘及岸上前景逐渐收回偏移，避免把岸边物体拉进水中。
 */
#ifndef LIB_WATER_REFRACTION_GLSL
#define LIB_WATER_REFRACTION_GLSL
#include "water.glsl"
#include "space.glsl"

vec2 waterRefractionUv(vec2 uv, vec3 position, vec3 normal, vec3 bedWorld,
                       vec3 bedNormal, sampler2D opaqueDepth) {
    if (WATER_REFRACTION_STRENGTH <= 0.0) {
        return uv;
    }
    vec3 origin = viewToAbsoluteWorld(position);
    vec3 incident = normalize(position);
    vec3 direction = normalize(mat3(gbufferModelViewInverse)
        * refract(incident, normal, 1.0 / WATER_IOR));
    float denominator = dot(bedNormal, direction);
    if (abs(denominator) < 0.04 || direction.y > -0.02) {
        return uv;
    }
    float distance = clamp(dot(bedNormal, bedWorld - origin) / denominator, 0.0, 48.0);
    vec2 candidate = uv;
    for (int index = 0; index < 3; index++) {
        vec3 target = origin + direction * distance;
        vec4 clip = gbufferProjection * vec4(worldToView(target - cameraPosition), 1.0);
        if (clip.w <= 0.001) {
            break;
        }
        vec2 projected = clip.xy / clip.w * 0.5 + 0.5;
        float edge = min(min(projected.x, projected.y), min(1.0 - projected.x, 1.0 - projected.y));
        projected = mix(uv, projected, smoothstep(0.005, 0.06, edge) * WATER_REFRACTION_STRENGTH);
        float depth = texture2D(opaqueDepth, projected).r;
        if (depth >= 0.999999) {
            break;
        }
        vec3 sampled = viewToAbsoluteWorld(screenToView(projected, depth));
        if (sampled.y > origin.y - 0.015 || length(sampled - cameraPosition) < length(position)) {
            break;
        }
        candidate = projected;
        float correction = dot(bedNormal, sampled - target) / denominator;
        distance = clamp(distance + correction, 0.0, 48.0);
    }
    return candidate;
}
#endif
