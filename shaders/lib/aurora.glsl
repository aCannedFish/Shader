/* Optically thin emissive curtains in a spherical upper-atmosphere shell.
 * Evaluated in the small sky LUT, shared by sky, water and opaque reflections.
 * The emission follows a stylised green oxygen band with purple/red fringes;
 * it has no screen-space derivatives, longitude seam or horizon division.
 */
#ifndef LIB_AURORA_GLSL
#define LIB_AURORA_GLSL
#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"
#include "atmosphere_noise.glsl"

float auroraShellDistance(vec3 origin, vec3 direction, float radius) {
    float b = dot(origin, direction);
    float c = dot(origin, origin) - radius * radius;
    return max(-b + sqrt(max(b * b - c, 0.0)), 0.0);
}

vec3 auroraRadiance(vec3 direction) {
#if SIMPLE_DIMENSION != 0
    return vec3(0.0);
#else
    vec3 sun = safeNormalize(mat3(gbufferModelViewInverse) * sunPosition, vec3(0.0, 1.0, 0.0));
    float night = 1.0 - smoothstep(-0.22, -0.07, sun.y);
    if (AURORA_STRENGTH <= 0.0 || night <= 0.001 || direction.y <= 0.015) {
        return vec3(0.0);
    }
    const float radius = 6371.0;
    vec3 origin = vec3(0.0, radius + clamp(cameraPosition.y * 0.001, 0.05, 4.0), 0.0);
    float start = auroraShellDistance(origin, direction, radius + 90.0);
    float end = auroraShellDistance(origin, direction, radius + 150.0);
    float phase = frameTimeCounter * TAU / 3600.0 * float(AURORA_SPEED);
    vec2 drift = vec2(sin(phase * 3.0), cos(phase * 3.0)) * 0.8;
    vec3 radiance = vec3(0.0);
    for (int index = 0; index < AURORA_STEPS; index++) {
        float t = (float(index) + 0.5) / float(AURORA_STEPS);
        vec3 position = origin + direction * mix(start, end, t);
        float height = clamp((length(position) - radius - 90.0) / 60.0, 0.0, 1.0);
        vec2 p = position.xz * 0.012 + drift * 0.25;
        float warp = atmosphereNoise2(vec2(p.x * 0.45, 11.5), 128.0) - 0.5;
        float curve = -2.10 + sin(p.x * 0.85 + phase * 3.0) * 0.45 + warp * 0.32;
        float farCurve = -4.60 + sin(p.x * 0.60 - phase * 2.0 + 1.7) * 0.65;
        float ribbon = p.y - curve;
        float farRibbon = p.y - farCurve;
        float baseWidth = mix(0.11, 0.18, height);
        float angularPixel = TAU / max(floor(viewWidth * 0.125), 1.0);
        float footprint = length(position - origin) * 0.012 * angularPixel / 3.464;
        float width = sqrt(baseWidth * baseWidth + footprint * footprint);
        float curtain = exp(-ribbon * ribbon / (width * width));
        curtain += 0.55 * exp(-farRibbon * farRibbon / (width * width * 1.5));
        float strands = atmosphereNoise2(vec2(p.x * 9.0 + drift.x, 7.5), 128.0);
        float vertical = smoothstep(0.0, 0.07, height) * exp(-height * 2.4);
        float density = curtain * vertical * (0.35 + 0.65 * strands * strands) * baseWidth / width;
        vec3 colour = mix(vec3(0.06, 0.90, 0.32), vec3(0.55, 0.045, 0.16), smoothstep(0.40, 1.0, height));
        colour += vec3(0.22, 0.045, 0.30) * exp(-pow((height - 0.10) / 0.10, 2.0));
        radiance += colour * density / float(AURORA_STEPS);
    }
    float moon = 0.5 + 0.5 * cos(float(moonPhase) * PI * 0.25);
    float north = mix(0.25, 1.0, smoothstep(-0.15, 0.65, -direction.z));
    float activity = 0.75 + 0.25 * sin(float(worldDay) * 1.618 + 0.7);
    return radiance * 2.0 * AURORA_STRENGTH * night * north * activity
         * (1.0 - rainStrength * 0.95) * mix(1.0, 0.65, moon)
         * smoothstep(0.015, 0.12, direction.y);
#endif
}
#endif
