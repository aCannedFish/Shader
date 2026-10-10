/* Water absorption and illuminated in-scattering shared by surface/underwater optics. */
#ifndef LIB_WATER_VOLUME_GLSL
#define LIB_WATER_VOLUME_GLSL

#include "/settings.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/lighting.glsl"

vec3 waterExtinctionCoefficient() {
    vec3 absorption = mix(vec3(0.12, 0.045, 0.022), vec3(0.045, 0.02, 0.01), WATER_COLOR_LIGHTNESS);
    return absorption * WATER_ABSORPTION + vec3(WATER_TURBIDITY);
}

// Local light is independent of daylight; no fixed blue glow is added to dark caves.
vec3 underwaterScatterColor(float eyeDepth) {
    float skyLevel = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
    float localLevel = clamp(float(eyeBrightnessSmooth.x) / 240.0, 0.0, 1.0);
    vec3 sky = toLinearSpace(skyColor);
    float skyMaximum = max(max(sky.r, sky.g), max(sky.b, 0.001));
    vec3 skyTint = sky / skyMaximum;
    float depthFade = exp(-eyeDepth * 0.055 * UNDERWATER_DEPTH_DIMMING);
    vec3 daylight = vec3(0.055, 0.13, 0.16) * skyTint * skyLevel * skyLevel
                  * (0.06 + 0.94 * getDayFactor()) * depthFade;
    vec3 local = vec3(0.13, 0.065, 0.022) * pow(localLevel, 3.0) * BLOCK_LIGHT_STRENGTH;
    return daylight + local + vec3(0.018, 0.030, 0.038) * UNDERWATER_MIN_VISIBILITY;
}

vec3 applyUnderwaterVolume(vec3 radiance, float pathLength, float eyeDepth) {
    vec3 coefficient = waterExtinctionCoefficient() * vec3(1.4, 1.7, 1.9)
                     + vec3(0.012);
    coefficient *= UNDERWATER_DENSITY * FOG_DENSITY;
    vec3 transmittance = exp(-coefficient * clamp(pathLength, 0.0, 256.0));
    // A limited near-field floor keeps navigation possible at any immersion depth.
    // It fades away by 18 blocks, so distant shallow geometry remains obscured.
    float nearVisibility = 1.0 - smoothstep(9.0, 18.0, pathLength);
    float minimumTransmission = min(UNDERWATER_MIN_VISIBILITY * 4.0, 0.75) * nearVisibility;
    transmittance = max(transmittance, vec3(minimumTransmission));
    return radiance * transmittance + underwaterScatterColor(eyeDepth) * (1.0 - transmittance);
}

#endif
