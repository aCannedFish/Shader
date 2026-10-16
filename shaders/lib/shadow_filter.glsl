/* 共享 PCSS 近似：遮挡搜索决定半影宽度，接收面斜率补偿避免掠射光的阴影脱离。 */
#ifndef LIB_SHADOW_FILTER_GLSL
#define LIB_SHADOW_FILTER_GLSL
#include "space.glsl"
#include "lighting.glsl"

// 透明几何在 shadowtex0，仅不透明几何在 shadowtex1；shadowcolor0 记录最近投影体类别。
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;

// 阴影纹素中心先做深度比较，再插值比较结果，供体积光与水体共享。
float filteredShadowVisibility(sampler2D depthMap, vec2 uv, float receiver) {
    float resolution = shadowTextureResolution();
    float texel = 1.0 / resolution;
    vec2 pixel = uv * resolution - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    float visibility = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 sampleUv = (base + vec2(float(x), float(y)) + 0.5) * texel;
            sampleUv = clamp(sampleUv, vec2(texel * 0.5), vec2(1.0 - texel * 0.5));
            float depth = texture2D(depthMap, sampleUv).r;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y);
            visibility += step(receiver, depth) * weight;
        }
    }
    return visibility;
}

// 斜率补偿必须使用实际读到的阴影纹素中心，避免最近邻采样误差变成自阴影。
vec2 shadowTexelCenter(vec2 uv) {
    float resolution = shadowTextureResolution();
    return (clamp(floor(uv * resolution), vec2(0.0), vec2(resolution - 1.0))
            + 0.5) / resolution;
}

vec2 shadowDiskOffset(int index, int count) {
    float angle = float(index) * 2.39996323;
    float radius = sqrt((float(index) + 0.5) / float(count));
    return vec2(cos(angle), sin(angle)) * radius;
}

// 屏幕导数转换为阴影 UV 上的接收面深度斜率。
vec2 shadowReceiverGradient(vec3 coordinate) {
    vec3 dx = dFdx(coordinate);
    vec3 dy = dFdy(coordinate);
    float first = dx.x * dy.y;
    float second = dx.y * dy.x;
    float determinant = first - second;
    // 用相对退化判据，避免高分辨率或近处表面的有效小导数被直接清零。
    float scale = max(abs(first), abs(second));
    if (abs(determinant) <= scale * 0.00001) {
        return vec2(0.0);
    }
    return clamp(vec2(dx.z * dy.y - dy.z * dx.y,
                      dy.z * dx.x - dx.z * dy.x) / determinant,
                 vec2(-3.0), vec2(3.0));
}

// 公共接收端设置：畸变后的阴影坐标、接收面斜率补偿、偏移后的接收深度与距离淡出。
bool prepareDirectionalShadow(vec4 clipPosition, vec3 normalView, float viewDistance,
                              out vec3 uv, out vec2 gradient, out float receiver,
                              out float fade, out float distortion) {
    // 在插值后畸变，保持采样投影与实际接收点一致。
    vec3 clip = clipPosition.xyz / max(clipPosition.w, EPSILON);
    distortion = (1.0 - SHADOW_MAP_BIAS) + length(clip.xy) * SHADOW_MAP_BIAS;
    uv = distortShadow(clip) * 0.5 + 0.5;
    gradient = shadowReceiverGradient(uv);
    fade = 1.0 - smoothstep(shadowDistance * 0.75, shadowDistance * 0.95, viewDistance);
    float incidence = max(dot(normalView, getLightDirView()), 0.0);
    receiver = uv.z;
    if (clipPosition.w <= 0.0 || fade <= 0.0 || incidence <= 0.001
        || any(lessThan(uv, vec3(0.0))) || any(greaterThan(uv, vec3(1.0)))) {
        return false;
    }
    float texel = 1.0 / shadowTextureResolution();
    // 栅格化后的畸变三角形仍有有限精度误差；保留有界基础偏移，
    // 不再按掠射角放大八倍，样本之间的斜率由接收面补偿处理。
    float bias = max(0.000001,
        min(SHADOW_BIAS * (0.5 + 0.5 * distortion), texel * 0.75));
    // 半纹素覆盖内的深度变化作为有界容差，修正低角度平地自遮挡。
    bias += 0.5 * texel * (abs(gradient.x) + abs(gradient.y));
    receiver = uv.z - bias;
    return true;
}

// 正交投影的深度差对应沿光线的世界距离（方块）。
float shadowDepthToBlocks(float depth) {
    return depth * 2.0 / max(abs(shadowProjection[2][2]), EPSILON);
}

// 畸变后阴影 UV 中一个方块的近似跨度。
float shadowUvPerBlock(float distortion) {
    return 0.5 * max(abs(shadowProjection[0][0]), abs(shadowProjection[1][1]))
         / max(distortion, 0.05);
}

// PCSS 滤波半径：遮挡距离越远半影越宽。
float shadowFilterRadius(float separation, float distortion) {
    float texel = 1.0 / shadowTextureResolution();
    float uvPerBlock = shadowUvPerBlock(distortion);
    return clamp(separation * 0.00465 * uvPerBlock * float(SHADOW_SOFTNESS),
                 texel * 0.7, texel * 8.0 * float(SHADOW_SOFTNESS));
}

float sampleSoftDirectionalShadow(sampler2D depthMap, vec4 clipPosition,
                                  vec3 normalView, float viewDistance) {
#if ENABLE_SHADOWS == 0
    return 1.0;
#else
    vec3 uv;
    vec2 gradient;
    float receiver;
    float fade;
    float distortion;
    if (!prepareDirectionalShadow(clipPosition, normalView, viewDistance,
                                  uv, gradient, receiver, fade, distortion)) {
        return 1.0;
    }
    float texel = 1.0 / shadowTextureResolution();
#if SHADOW_SOFTNESS == 0
    vec2 sampleUv = shadowTexelCenter(uv.xy);
    float visibility = step(receiver + dot(gradient, sampleUv - uv.xy),
                            texture2D(depthMap, sampleUv).r);
#else
    const int blockerSamples = SHADOW_SOFTNESS == 1 ? 5 : 9;
    const int filterSamples = SHADOW_SOFTNESS == 1 ? 8 : 12;
    float blockerSum = 0.0;
    float blockers = 0.0;
    float searchRadius = texel * (4.0 + 4.0 * float(SHADOW_SOFTNESS));
    for (int index = 0; index < blockerSamples; index++) {
        vec2 offset = index == 0 ? vec2(0.0)
            : shadowDiskOffset(index - 1, blockerSamples - 1) * searchRadius;
        vec2 sampleUv = shadowTexelCenter(uv.xy + offset);
        float sampleDepth = texture2D(depthMap, sampleUv).r;
        float centerDepth = sampleDepth - dot(gradient, sampleUv - uv.xy);
        if (centerDepth < receiver) {
            blockerSum += centerDepth;
            blockers += 1.0;
        }
    }
    if (blockers < 0.5) {
        return 1.0;
    }
    float separation = shadowDepthToBlocks(max(receiver - blockerSum / blockers, 0.0));
    float radius = shadowFilterRadius(separation, distortion);
    float visibility = 0.0;
    for (int index = 0; index < filterSamples; index++) {
        vec2 offset = shadowDiskOffset(index, filterSamples) * radius;
        vec2 sampleUv = shadowTexelCenter(uv.xy + offset);
        float depth = texture2D(depthMap, sampleUv).r;
        visibility += step(receiver + dot(gradient, sampleUv - uv.xy), depth);
    }
    visibility /= float(filterSamples);
#endif
    return mix(1.0, visibility, fade);
#endif
}

#endif
