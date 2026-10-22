/* 水面短波与像素足迹过滤。几何保留较长的波浪，细小风浪只改变法线。
 * 无法被当前像素分辨的频率逐渐退出，避免远处波纹与高光闪烁。
 */
#ifndef LIB_WATER_SURFACE_GLSL
#define LIB_WATER_SURFACE_GLSL
#include "water.glsl"
#include "weather.glsl"

vec2 waterPhaseHash(vec2 cell) {
    vec3 p = fract(vec3(cell.x, cell.y, cell.x) * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yzx + 33.33);
    return fract((p.xx + p.yz) * p.zy) * 2.0 - 1.0;
}

// Smooth world-space phase patches break long parallel sine-wave bands. The
// cubic interpolation keeps phase and its first derivative continuous at cells.
vec2 waterPhaseWarp(vec2 position, float time) {
    vec2 p = position / 9.0 + vec2(time * 0.027, -time * 0.019);
    vec2 cell = floor(p);
    vec2 f = fract(p);
    vec2 blend = f * f * (3.0 - 2.0 * f);
    vec2 lower = mix(waterPhaseHash(cell), waterPhaseHash(cell + vec2(1, 0)), blend.x);
    vec2 upper = mix(waterPhaseHash(cell + vec2(0, 1)), waterPhaseHash(cell + vec2(1)), blend.x);
    return mix(lower, upper, blend.y) * 2.4;
}

vec2 waterRippleSlope(vec2 position, vec2 wave, float time, float speed,
                      float amplitude, float footprint) {
    float attenuation = 1.0 - smoothstep(0.35, 0.90, footprint * length(wave));
    return cos(dot(position, wave) + time * speed) * amplitude * wave * attenuation;
}

vec3 waterSurfaceNormal(vec2 position, float time, float footprint) {
    vec2 phase = position + waterPhaseWarp(position, time);
    // The phase warp stretches local frequencies; include that bound in the
    // footprint and fade unresolved long waves as well as the short ripples.
    float filteredFootprint = footprint * 1.8;
    vec3 base = getWaterWaveNormal(phase, time);
    vec2 slope = -base.xz / max(base.y, 0.1);
    slope *= 1.0 - smoothstep(0.35, 0.90, filteredFootprint * 1.4);
    vec2 ripple = waterRippleSlope(phase, vec2(2.8, 1.7), time, 2.4, 0.008, filteredFootprint);
    ripple += waterRippleSlope(phase, vec2(-4.1, 3.4), time, -3.1, 0.004, filteredFootprint);
    ripple += waterRippleSlope(phase, vec2(6.5, -2.7), time, 4.2, 0.0025, filteredFootprint);
    slope += ripple * mix(1.0, 1.30, weatherRainAmount());
    return normalize(vec3(-slope.x, 1.0, -slope.y));
}

#endif
