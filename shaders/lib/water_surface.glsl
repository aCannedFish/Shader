/* 水面短波与像素足迹过滤。几何保留较长的波浪，细小风浪只改变法线。
 * 无法被当前像素分辨的频率逐渐退出，避免远处波纹与高光闪烁。
 */
#ifndef LIB_WATER_SURFACE_GLSL
#define LIB_WATER_SURFACE_GLSL
#include "water.glsl"
#include "weather.glsl"

vec2 waterRippleSlope(vec2 position, vec2 wave, float time, float speed,
                      float amplitude, float footprint) {
    float attenuation = 1.0 - smoothstep(0.35, 0.90, footprint * length(wave));
    return cos(dot(position, wave) + time * speed) * amplitude * wave * attenuation;
}

vec3 waterSurfaceNormal(vec2 position, float time, float footprint) {
    vec3 base = getWaterWaveNormal(position, time);
    vec2 slope = -base.xz / max(base.y, 0.1);
    vec2 phase = position + vec2(sin(dot(position, vec2(0.71, 0.39)) + time * 0.3),
                                 cos(dot(position, vec2(-0.43, 0.63)) - time * 0.24)) * 0.18;
    vec2 ripple = waterRippleSlope(phase, vec2(2.8, 1.7), time, 2.4, 0.008, footprint);
    ripple += waterRippleSlope(phase, vec2(-4.1, 3.4), time, -3.1, 0.004, footprint);
    ripple += waterRippleSlope(phase, vec2(6.5, -2.7), time, 4.2, 0.0025, footprint);
    slope += ripple * mix(1.0, 1.30, weatherRainAmount());
    return normalize(vec3(-slope.x, 1.0, -slope.y));
}

#endif
