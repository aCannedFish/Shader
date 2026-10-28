/* 世界坐标中的雨滴波环。四个邻域滴点使用解析斜率，避免纹理动画的平铺和跳帧。
 * 半径小于胞元的一半，四邻域足够覆盖；像素足迹过大时连续退出。
 */
#ifndef LIB_RAIN_RIPPLES_GLSL
#define LIB_RAIN_RIPPLES_GLSL
#include "weather.glsl"

vec3 rainImpactHash(vec2 cell) {
    vec3 value = fract(vec3(cell.xyx) * vec3(0.1031, 0.1030, 0.0973));
    value += dot(value, value.yxz + 33.33);
    return fract((value.xxy + value.yzz) * value.zyx);
}

vec2 rainRippleSlope(vec2 world, float time, float footprint) {
    float rain = weatherRainAmount() * clamp(rainBiome, 0.0, 1.0);
    float resolved = 1.0 - smoothstep(0.035, 0.22, footprint);
    if (RAIN_RIPPLE_STRENGTH <= 0.0 || rain * resolved <= 0.001) {
        return vec2(0.0);
    }
    const float cellSize = 1.6;
    vec2 coordinate = world / cellSize;
    vec2 base = floor(coordinate - 0.5);
    vec2 slope = vec2(0.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = base + vec2(float(x), float(y));
            vec3 seed = rainImpactHash(cell);
            float clock = time * mix(0.9, 1.4, seed.z) + seed.x * 7.0;
            float age = fract(clock);
            vec3 impact = rainImpactHash(cell + floor(clock) * vec2(13.7, 29.3));
            vec2 centre = (cell + 0.3 + impact.xy * 0.4) * cellSize;
            vec2 delta = world - centre;
            float distance = length(delta);
            float radius = 0.035 + age * 0.40;
            float width = sqrt(0.018 * 0.018 + footprint * footprint * 0.7);
            float ring = (distance - radius) / width;
            float envelope = smoothstep(0.0, 0.08, age) * (1.0 - age) * (1.0 - age);
            float derivative = -ring * exp(-0.5 * ring * ring) * 0.004 / width;
            slope += delta / max(distance, 0.001) * derivative * envelope;
        }
    }
    return slope * rain * resolved * RAIN_RIPPLE_STRENGTH;
}
#endif
