/* 连续天气响应。天空、日照和环境光共用雨量，地表积水另用滞后的湿度。
 * 主世界以外保留各维度原有环境，雨停后的地表不会立即恢复干燥。
 */
#ifndef LIB_WEATHER_GLSL
#define LIB_WEATHER_GLSL
#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"

uniform float rainBiome;

float weatherRainAmount() {
#if SIMPLE_DIMENSION != 0
    return 0.0;
#else
    return smoothstep(0.0, 1.0, rainStrength);
#endif
}

vec3 weatherSkyRadiance(vec3 clearSky) {
    float rain = weatherRainAmount();
    float brightness = luma(clearSky);
    vec3 overcast = vec3(0.92, 0.96, 1.0) * brightness * 0.62;
    return mix(clearSky, overcast, rain * 0.96);
}

float weatherGroundWetness() {
#if SIMPLE_DIMENSION != 0
    return 0.0;
#else
    return clamp(wetness, 0.0, 1.0) * clamp(rainBiome, 0.0, 1.0);
#endif
}

// 原版落地水花的贴图具有明显的纯蓝分量，灵魂火等青色粒子不满足此色差。
// 仅在主世界降雨、相机未入水时调整，保留普通粒子和水下粒子的原色。
vec3 weatherParticleColor(vec3 texel) {
    if (isEyeInWater != 0 || weatherRainAmount() <= 0.001 || rainBiome <= 0.001) {
        return texel;
    }
    float splash = smoothstep(0.25, 0.38, texel.b - max(texel.r, texel.g));
    vec3 water = vec3(0.07, 0.11, 0.17) * mix(0.7, 1.2, luma(texel));
    return mix(texel, water, splash * rainBiome);
}

#endif
