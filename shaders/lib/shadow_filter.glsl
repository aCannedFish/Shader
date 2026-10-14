/* 共享 PCSS 近似：遮挡搜索决定半影宽度，接收面斜率补偿避免掠射光的阴影脱离。 */
#ifndef LIB_SHADOW_FILTER_GLSL
#define LIB_SHADOW_FILTER_GLSL
#include "space.glsl"
#include "lighting.glsl"

vec2 shadowDiskOffset(int index, int count) {
    float angle = float(index) * 2.39996323;
    float radius = sqrt((float(index) + 0.5) / float(count));
    return vec2(cos(angle), sin(angle)) * radius;
}

// 屏幕导数转换为阴影 UV 上的接收面深度斜率。
vec2 shadowReceiverGradient(vec3 coordinate) {
    vec3 dx = dFdx(coordinate);
    vec3 dy = dFdy(coordinate);
    float determinant = dx.x * dy.y - dx.y * dy.x;
    if (abs(determinant) < 0.0000000001) {
        return vec2(0.0);
    }
    return clamp(vec2(dx.z * dy.y - dy.z * dx.y,
                      dy.z * dx.x - dx.z * dy.x) / determinant,
                 vec2(-3.0), vec2(3.0));
}

float sampleSoftDirectionalShadow(sampler2D depthMap, vec4 clipPosition,
                                  vec3 normalView, float viewDistance) {
#if ENABLE_SHADOWS == 0
    return 1.0;
#else
    // 在插值后畸变，保持采样投影与实际接收点一致。
    vec3 clip = clipPosition.xyz / max(clipPosition.w, EPSILON);
    float distortion = (1.0 - SHADOW_MAP_BIAS) + length(clip.xy) * SHADOW_MAP_BIAS;
    vec3 uv = distortShadow(clip) * 0.5 + 0.5;
    vec2 gradient = shadowReceiverGradient(uv);
    float fade = 1.0 - smoothstep(shadowDistance * 0.75, shadowDistance * 0.95, viewDistance);
    float incidence = max(dot(normalView, getLightDirView()), 0.0);
    if (clipPosition.w <= 0.0 || fade <= 0.0 || incidence <= 0.001
        || any(lessThan(uv, vec3(0.0))) || any(greaterThan(uv, vec3(1.0)))) {
        return 1.0;
    }
    float texel = 1.0 / float(shadowMapResolution);
    // 栅格化后的畸变三角形仍有有限精度误差；保留有界基础偏移，
    // 不再按掠射角放大八倍，样本之间的斜率由接收面补偿处理。
    float bias = max(0.000001,
        min(SHADOW_BIAS * (0.5 + 0.5 * distortion), texel * 0.75));
    float receiver = uv.z - bias;
#if SHADOW_SOFTNESS == 0
    float visibility = step(receiver, texture2D(depthMap, uv.xy).r);
#else
    const int blockerSamples = SHADOW_SOFTNESS == 1 ? 5 : 9;
    const int filterSamples = SHADOW_SOFTNESS == 1 ? 8 : 12;
    float blockerSum = 0.0;
    float blockers = 0.0;
    float searchRadius = texel * (4.0 + 4.0 * float(SHADOW_SOFTNESS));
    for (int index = 0; index < blockerSamples; index++) {
        vec2 offset = index == 0 ? vec2(0.0)
            : shadowDiskOffset(index - 1, blockerSamples - 1) * searchRadius;
        float sampleDepth = texture2D(depthMap, clamp(uv.xy + offset, texel, 1.0 - texel)).r;
        float centerDepth = sampleDepth - dot(gradient, offset);
        if (centerDepth < receiver) {
            blockerSum += centerDepth;
            blockers += 1.0;
        }
    }
    if (blockers < 0.5) {
        return 1.0;
    }
    // 正交投影的深度差对应沿光线的世界距离。
    float separation = max(receiver - blockerSum / blockers, 0.0)
                     * 2.0 / max(abs(shadowProjection[2][2]), EPSILON);
    float uvPerBlock = 0.5 * max(abs(shadowProjection[0][0]), abs(shadowProjection[1][1]))
                     / max(distortion, 0.05);
    float radius = clamp(separation * 0.00465 * uvPerBlock * float(SHADOW_SOFTNESS),
                         texel * 0.7, texel * 8.0 * float(SHADOW_SOFTNESS));
    float visibility = 0.0;
    for (int index = 0; index < filterSamples; index++) {
        vec2 offset = shadowDiskOffset(index, filterSamples) * radius;
        float depth = texture2D(depthMap, clamp(uv.xy + offset, texel, 1.0 - texel)).r;
        visibility += step(receiver + dot(gradient, offset), depth);
    }
    visibility /= float(filterSamples);
#endif
    return mix(1.0, visibility, fade);
#endif
}

#endif
