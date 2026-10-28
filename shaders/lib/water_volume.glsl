/* Water absorption and illuminated in-scattering shared by surface/underwater optics. */
#ifndef LIB_WATER_VOLUME_GLSL
#define LIB_WATER_VOLUME_GLSL

#include "../settings.glsl"
#include "uniforms.glsl"
#include "lighting.glsl"

vec3 waterExtinctionCoefficient() {
    vec3 absorption = mix(vec3(0.12, 0.045, 0.022), vec3(0.045, 0.02, 0.01), WATER_COLOR_LIGHTNESS);
    return absorption * WATER_ABSORPTION + vec3(WATER_TURBIDITY);
}

// 水下表面与光柱共用同一消光模型，红色比蓝色更快衰减。
// 各向同性散射单独保留，最低能见度只放宽雾遮蔽，不恢复已吸收的颜色。
float underwaterScatteringCoefficient() {
    return (WATER_TURBIDITY + 0.018) * UNDERWATER_DENSITY * FOG_DENSITY;
}

vec3 underwaterExtinctionCoefficient() {
    vec3 absorption = (waterExtinctionCoefficient() - vec3(WATER_TURBIDITY))
                    * vec3(1.8, 1.1, 0.95) * UNDERWATER_DENSITY * FOG_DENSITY;
    return absorption + vec3(underwaterScatteringCoefficient());
}

// 水下先形成低亮度的蓝色基调，再叠加距离雾；近处不再保持空气中的白亮色。
// 方块光占优时减弱冷色过滤，让火把、岩浆等局部光源保留自身色相。
vec3 underwaterSceneTint(float eyeDepth, float surfaceSky) {
    float skyLevel = clamp(surfaceSky, 0.0, 1.0);
    float localLevel = clamp(float(eyeBrightnessSmooth.x) / 240.0, 0.0, 1.0);
    float skyWeight = smoothstep(0.02, 0.45, skyLevel) * (1.0 - localLevel * 0.75);
    float depth = 1.0 - exp(-min(eyeDepth, 32.0) * 0.12 * UNDERWATER_DEPTH_DIMMING);
    vec3 tint = mix(vec3(0.12, 0.38, 0.62), vec3(0.06, 0.27, 0.49), depth);
    tint *= mix(0.65, 1.0, getDayFactor());
    return mix(vec3(0.72, 0.84, 0.94), tint, skyWeight);
}

// Local light is independent of daylight; no fixed blue glow is added to dark caves.
vec3 underwaterScatterColor(float eyeDepth, float surfaceSky) {
    float cameraSky = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
    float skyLevel = clamp(surfaceSky, 0.0, 1.0);
    float localLevel = clamp(float(eyeBrightnessSmooth.x) / 240.0, 0.0, 1.0);
    vec3 sky = toLinearSpace(skyColor);
    float skyMaximum = max(max(sky.r, sky.g), max(sky.b, 0.001));
    vec3 skyTint = sky / skyMaximum;
    float depthFade = 0.45 + 0.55 * exp(-eyeDepth * 0.04 * UNDERWATER_DEPTH_DIMMING);
    // 深水中用有界曝光补偿保留蓝色雾光；其能量仍由水面天光限制。
    // 封闭水域的 surfaceSky 和 cameraSky 均低，不会因补偿获得室外照明。
    float adaptation = mix(1.0, 3.0, 1.0 - smoothstep(0.05, 0.50, cameraSky));
    vec3 daylight = vec3(0.001, 0.10, 0.20) * mix(vec3(1.0), skyTint, 0.25) * skyLevel * skyLevel
                  * (0.06 + 0.94 * getDayFactor()) * depthFade * adaptation;
    vec3 local = vec3(0.13, 0.065, 0.022) * pow(localLevel, 3.0) * BLOCK_LIGHT_STRENGTH;
    return daylight + local + vec3(0.004, 0.025, 0.045) * UNDERWATER_MIN_VISIBILITY;
}

vec3 applyUnderwaterVolume(vec3 radiance, float pathLength, vec3 sceneTint, vec3 scatterColor) {
    float distance = clamp(pathLength, 0.0, 256.0);
    vec3 transmittance = exp(-underwaterExtinctionCoefficient() * distance);
    // A limited near-field floor keeps navigation possible at any immersion depth.
    // It fades away by 18 blocks, so distant shallow geometry remains obscured.
    float nearVisibility = 1.0 - smoothstep(9.0, 18.0, pathLength);
    float minimumTransmission = min(UNDERWATER_MIN_VISIBILITY * 4.0, 0.75) * nearVisibility;
    float scatteringTransmission = exp(-underwaterScatteringCoefficient() * distance);
    transmittance *= max(scatteringTransmission, minimumTransmission)
                   / max(scatteringTransmission, EPSILON);
    return radiance * sceneTint * transmittance + scatterColor * (1.0 - transmittance);
}

#endif
