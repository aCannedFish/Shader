/* 日月阴影入口。返回 RGB 光传递：不透明遮挡为 0，彩色玻璃按透射色染色，
 * 发光方块以自身颜色按遮挡距离照亮它投下的阴影。
 */
#ifndef LIB_SHADOW_GLSL
#define LIB_SHADOW_GLSL
#include "shadow_filter.glsl"

// 发光方块对其阴影的补光：紧贴光源处几乎完全照亮，约 15 格（最大光照等级）后消失。
const float SHADOW_EMITTER_FILL = 0.85;

// shadowcolor0 只记录离太阳最近的投影体，看不到发光体背后的实体。
// 发光体在阴影图上只占很小的面积：若周围一格内的光线在到达接收面前已被不透明体挡住，
// 说明发光体与接收点之间还隔着实体（如方块顶上的火把投到方块背后），此时不补光。
bool shadowEmitterOccluded(vec2 sampleUv, float receiver, vec2 gradient, float uvPerBlock) {
    // 接收面起伏半格以内不算遮挡。
    float margin = 0.25 * abs(shadowProjection[2][2]);
    for (int index = 0; index < 6; index++) {
        vec2 tapUv = shadowTexelCenter(sampleUv + shadowDiskOffset(index, 6) * uvPerBlock);
        if (abs(texture2D(shadowcolor0, tapUv).a - 0.75) < 0.125) {
            continue;
        }
        float tapReceiver = receiver + dot(gradient, tapUv - sampleUv);
        if (texture2D(shadowtex1, tapUv).r < tapReceiver - margin) {
            return true;
        }
    }
    return false;
}

// 单个滤波样本的 RGB 传递。仅在 shadowtex0 显示遮挡时读取类别，未遮挡样本不增加开销。
vec3 shadowSampleTransfer(vec2 sampleUv, float receiver, float depth,
                          vec2 gradient, float uvPerBlock) {
    if (receiver <= depth) {
        return vec3(1.0);
    }
    vec4 caster = texture2D(shadowcolor0, sampleUv);
    // 只认 shadow.fsh 写入的类别标记；其余 alpha（含白色清屏值）都是不透明遮挡。
    if (abs(caster.a - 0.75) < 0.125) {
        if (shadowEmitterOccluded(sampleUv, receiver, gradient, uvPerBlock)) {
            return vec3(0.0);
        }
        float separation = shadowDepthToBlocks(receiver - depth);
        vec3 hue = toLinearSpace(caster.rgb);
        hue /= max(max(hue.r, hue.g), max(hue.b, 0.001));
#if ENABLE_COLOURED_LIGHTING == 0
        hue = vec3(1.0);
#endif
        return hue * SHADOW_EMITTER_FILL * (1.0 - smoothstep(1.5, 15.0, separation));
    }
    // 半透明投影体之后若还有不透明遮挡，则仍为完整阴影。
    if (abs(caster.a - 0.5) < 0.125 && receiver <= texture2D(shadowtex1, sampleUv).r) {
#if ENABLE_COLOURED_LIGHTING == 0
        return vec3(luma(caster.rgb));
#else
        return caster.rgb;
#endif
    }
    return vec3(0.0);
}

vec3 getSurfaceShadowFactor(vec4 shadowClipPos, vec3 normalView, float viewDistance,
                            float lightmapY) {
#if SIMPLE_DIMENSION != 0
    return vec3(1.0);
#endif
#if ENABLE_SHADOWS == 0
    return vec3(1.0);
#else
    vec3 uv;
    vec2 gradient;
    float receiver;
    float fade;
    float distortion;
    // Keep derivatives outside the varying exposure branch. A surface receiving
    // no direct sky light cannot use solar visibility in either diffuse or GGX.
    bool prepared = prepareDirectionalShadow(shadowClipPos, normalView, viewDistance,
                                             uv, gradient, receiver, fade, distortion);
#if DEBUG_VIEW == 0
    if (lightmapLevel(lightmapY) <= 0.60) {
        return vec3(1.0);
    }
#endif
    if (!prepared) {
        return vec3(1.0);
    }
    float texel = 1.0 / shadowTextureResolution();
#if SHADOW_SOFTNESS == 0
    vec2 sampleUv = shadowTexelCenter(uv.xy);
    vec3 transfer = shadowSampleTransfer(sampleUv, receiver + dot(gradient, sampleUv - uv.xy),
                                         texture2D(shadowtex0, sampleUv).r,
                                         gradient, shadowUvPerBlock(distortion));
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
        float centerDepth = texture2D(shadowtex0, sampleUv).r - dot(gradient, sampleUv - uv.xy);
        if (centerDepth < receiver) {
            blockerSum += centerDepth;
            blockers += 1.0;
        }
    }
    if (blockers < 0.5) {
        return vec3(1.0);
    }
    float separation = shadowDepthToBlocks(max(receiver - blockerSum / blockers, 0.0));
    float radius = shadowFilterRadius(separation, distortion);
    float uvPerBlock = shadowUvPerBlock(distortion);
    vec3 transfer = vec3(0.0);
    for (int index = 0; index < filterSamples; index++) {
        vec2 sampleUv = shadowTexelCenter(uv.xy + shadowDiskOffset(index, filterSamples) * radius);
        transfer += shadowSampleTransfer(sampleUv, receiver + dot(gradient, sampleUv - uv.xy),
                                         texture2D(shadowtex0, sampleUv).r,
                                         gradient, uvPerBlock);
    }
    transfer /= float(filterSamples);
#endif
    return mix(vec3(1.0), transfer, fade);
#endif
}

// Other geometry retains its existing entry point and full shadow evaluation.
vec3 getShadowFactor(vec4 shadowClipPos, vec3 normalView, float viewDistance) {
    return getSurfaceShadowFactor(shadowClipPos, normalView, viewDistance, 1.0);
}

#endif
