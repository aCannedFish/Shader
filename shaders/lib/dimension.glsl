/* Dimension-local environment radiance. Nether fog follows the current biome;
 * the End has a fixed cool hemispherical fill and a continuous procedural void.
 * These are artistic ambient sources, independent of solar time and block light.
 */
#ifndef LIB_DIMENSION_GLSL
#define LIB_DIMENSION_GLSL
#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"
#include "color_space.glsl"
#include "atmosphere_noise.glsl"

vec3 dimensionFogColor() {
#if SIMPLE_DIMENSION == -1
    vec3 biome = max(toLinearSpace(fogColor), vec3(0.018, 0.006, 0.004));
    float low = 1.0 - smoothstep(28.0, 85.0, cameraPosition.y);
    float warmBiome = smoothstep(-0.02, 0.08, biome.r - biome.b);
    return mix(biome, biome * vec3(1.12, 0.92, 0.82) + vec3(0.020, 0.003, 0.001),
               NETHER_ATMOSPHERE * low * mix(0.08, 0.42, warmBiome));
#elif SIMPLE_DIMENSION == 1
    return mix(vec3(0.022, 0.016, 0.039), vec3(0.021, 0.020, 0.047), END_ATMOSPHERE * 0.60);
#else
    return toLinearSpace(fogColor);
#endif
}

vec3 dimensionAmbient(vec3 normalWorld) {
#if SIMPLE_DIMENSION == -1
    vec3 biome = dimensionFogColor();
    vec3 tint = mix(vec3(0.82, 0.64, 0.51), biome / max(luma(biome), 0.02), 0.18);
    tint = mix(tint, tint * vec3(1.05, 0.97, 0.92), NETHER_ATMOSPHERE * 0.45);
    return tint * NETHER_AMBIENT * (0.70 + 0.30 * max(-normalWorld.y, 0.0));
#elif SIMPLE_DIMENSION == 1
    return mix(vec3(0.46, 0.38, 0.62), vec3(0.75, 0.80, 1.0),
               normalWorld.y * 0.5 + 0.5) * END_AMBIENT
         + vec3(0.010, 0.020, 0.035) * END_ATMOSPHERE * max(normalWorld.y, 0.0);
#else
    return vec3(0.0);
#endif
}

vec3 dimensionBackground(vec3 direction) {
#if SIMPLE_DIMENSION == 1
    // Direction-only fields keep the void stable under camera translation and
    // avoid a longitude seam, polar singularity or a second apparent sun.
    float band = sin(direction.x * 4.0 + direction.y * 3.0)
               * sin(direction.z * 5.0 - direction.y * 2.0);
    float wisps = pow(clamp(band * 0.5 + 0.5, 0.0, 1.0), 4.0);
    vec3 p = direction * 540.0;
    float seed = hash13(floor(p));
    float star = (1.0 - smoothstep(0.08, 0.32, length(fract(p) - 0.5)))
               * step(0.9985, seed);
    vec3 base = dimensionFogColor() * (0.65 + wisps * 0.65)
              + vec3(0.30, 0.36, 0.50) * star * 0.35 * (1.0 - smoothstep(0.0, 0.1, END_ATMOSPHERE));
    float phase = frameTimeCounter * TAU / 3600.0;
    vec3 drift = vec3(sin(phase * 2.0), 0.0, cos(phase * 2.0)) * 0.20;
    float warp = atmosphereNoise3(direction * 3.0 + drift);
    float plane = dot(direction, normalize(vec3(0.35, 0.82, 0.24))) + (warp - 0.5) * 0.35;
    float nebula = exp(-plane * plane * 32.0);
    float detail = atmosphereNoise3(direction * 11.0 + drift);
    vec3 palette = mix(vec3(0.065, 0.018, 0.090), vec3(0.018, 0.075, 0.10), detail);
    return base + palette * nebula * (0.20 + detail * detail) * END_ATMOSPHERE;
#else
    return dimensionFogColor() * mix(0.85, 1.05, direction.y * 0.5 + 0.5);
#endif
}
#endif
