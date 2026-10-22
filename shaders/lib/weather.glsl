/* 连续天气响应。天空、日照和环境光共用雨量，地表积水另用滞后的湿度。
 * 主世界以外保留各维度原有环境，雨停后的地表不会立即恢复干燥。
 */
#ifndef LIB_WEATHER_GLSL
#define LIB_WEATHER_GLSL
#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"
#include "color_space.glsl"

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

// Rain streaks and impact particles share one display-space blue-grey palette.
vec3 rainDropAlbedo() {
    return vec3(0.09, 0.13, 0.19);
}

// Two spare water-parameter channels accumulate rain optical depth and its
// intensity moment. Constant-colour layers compose exactly; varying light uses
// an optical-depth-weighted mean without requiring a ninth macOS attachment.
vec4 rainOverlayMoments(float intensity, float alpha) {
    float opticalDepth = -log(max(1.0 - clamp(alpha, 0.0, 0.999), 0.001));
    return vec4(0.0, 0.0, opticalDepth * intensity, opticalDepth);
}

vec3 applyRainOverlay(vec3 background, vec4 parameters, bool waterPresent) {
    float opticalDepth = max(parameters.a - (waterPresent ? 1.0 : 0.0), 0.0);
    if (opticalDepth <= 0.00001) {
        return background;
    }
    float transmission = exp(-opticalDepth);
    vec3 tint = toLinearSpace(rainDropAlbedo());
    float intensity = parameters.b / opticalDepth;
    return background * transmission + tint * intensity * (1.0 - transmission);
}

// 原版水花的蓝色贴图及其低红色青色变体共用雨丝配色。
// 仅在降雨群系、相机未入水时调整；中性色、暖色及明亮青色不受影响。
float rainParticleWeight(vec3 texel) {
    if (isEyeInWater != 0 || weatherRainAmount() <= 0.001 || rainBiome <= 0.001) {
        return 0.0;
    }
    float blue = smoothstep(0.18, 0.32, texel.b - max(texel.r, texel.g));
    float cyan = (1.0 - smoothstep(0.04, 0.12, texel.r))
               * smoothstep(0.45, 0.65, min(texel.g, texel.b))
               * (1.0 - smoothstep(0.04, 0.10, abs(texel.g - texel.b)));
    return max(blue, cyan) * rainBiome;
}

#endif
