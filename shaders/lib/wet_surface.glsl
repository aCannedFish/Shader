/* 雨后地表薄水层。湿度控制积累与消退，连续噪声给出局部积水分布。
 * 法线、原生天光和已有地表高度共同限制范围，避免墙面、树叶与屋内地板积水。
 * 不改变世界几何；倒影复用现有单次反射与 mip 过滤。
 */
#ifndef LIB_WET_SURFACE_GLSL
#define LIB_WET_SURFACE_GLSL
#include "weather.glsl"
#include "ground_fog.glsl"
#include "cloud_density.glsl"
#include "lightmap.glsl"
#include "wave_noise.glsl"
#include "rain_ripples.glsl"

vec2 wetGroundCoverage(vec3 relative, vec3 normalWorld, float skyLight,
                      float kind, float footprint) {
    float wet = weatherGroundWetness() * RAIN_PUDDLES_STRENGTH * float(ENABLE_RAIN_PUDDLES);
    if (wet <= 0.001 || normalWorld.y <= 0.96 || (kind > 0.5 && kind < 5.5) || kind > 9.5) {
        return vec2(0.0);
    }
    float exposure = smoothstep(0.95, 0.995, lightmapLevel(skyLight));
    if (exposure <= 0.001) {
        return vec2(0.0);
    }
    if (hasTerrainAtmosphere()) {
        float coverage;
        vec4 field = sampleTerrainFog(relative.xz, terrainFogHeader(0.0), terrainFogHeader(1.0), coverage);
        float roof = 1.0 - smoothstep(1.2, 3.0, field.r - (cameraPosition.y + relative.y));
        exposure *= mix(1.0, roof, coverage);
    }
    vec2 world = atmosphereWorldXZ(relative.xz);
    float broad = cloudWeatherNoise(world * 0.18);
    float detail = cloudWeatherNoise(world * 0.47 + vec2(31.7, 9.1));
    float height = broad * 0.72 + detail * 0.28;
    float threshold = mix(0.86, 0.53, wet);
    float edge = 0.035 + min(footprint * 0.15, 0.12);
    float puddle = smoothstep(threshold - edge, threshold + edge, height) * wet * exposure;
    return vec2(wet * exposure, puddle);
}

// 积水中的轻微风雨扰动，雨停后逐渐平静；像素无法分辨的短波平滑消退。
// 与水面相同使用两层随机噪声而不是正弦，远处积水不再出现规则条纹。
vec3 wetSurfaceNormal(vec3 normalView, vec3 relative, float coverage, float footprint) {
    if (coverage <= 0.001 || weatherRainAmount() <= 0.001) {
        return normalView;
    }
    vec2 world = atmosphereWorldXZ(relative.xz);
    float time = frameTimeCounter;
    vec2 slope = waterWaveOctave(world, time, 0.52, 1.7, 1.5, 0.8, 0.035,
                                 vec2(5.3, -12.1), footprint);
    slope += waterWaveOctave(world, time, -0.61, 0.85, 1.3, 0.6, 0.012,
                             vec2(-37.7, 21.4), footprint);
    slope += rainRippleSlope(world, time, footprint);
    vec3 ripple = mat3(gbufferModelView) * vec3(-slope.x, 0.0, -slope.y);
    return normalize(normalView + ripple * coverage * weatherRainAmount());
}

#endif
