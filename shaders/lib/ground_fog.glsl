/* Outdoor terrain mist. The companion's reserved atlas rows contain ground
 * height, habitat, native sky/block exposure and validity at four-block spacing.
 * No screen-derived height plane is used: missing chunks and indoor columns do
 * not seed fog. Header-relative coordinates survive OptiFine origin rebasing.
 */
#ifndef LIB_GROUND_FOG_GLSL
#define LIB_GROUND_FOG_GLSL
#include "companion_lighting.glsl"
#include "atmosphere_noise.glsl"
#include "weather.glsl"

vec4 terrainFogHeader(float index) {
    return texture2D(companionAtlas, vec2(index + 0.5, 1.5) / companionAtlasSize());
}

bool hasTerrainAtmosphere() {
    return hasCompanionLighting() && abs(terrainFogHeader(0.0).w - 2718.0) < 0.5;
}

bool groundFogEnabled() {
#if SIMPLE_DIMENSION != 0
    return false;
#else
    return isEyeInWater == 0 && FOG_DENSITY > 0.0
        && (GROUND_FOG_STRENGTH > 0.0 || weatherRainAmount() * RAIN_FOG_STRENGTH > 0.001)
        && hasTerrainAtmosphere() && terrainFogHeader(1.0).w > 0.001;
#endif
}

vec4 terrainFogCell(vec2 cell, float side) {
    vec2 size = companionAtlasSize();
    float index = 2.0 + cell.y * side + cell.x;
    return texture2D(companionAtlas, vec2(mod(index, size.x) + 0.5,
                     1.5 + floor(index / size.x)) / size);
}

vec4 decodeTerrainFogCell(vec4 cell) {
    float packedLight = floor(cell.b + 0.5);
    return vec4(cell.r, cell.g, floor(packedLight / 16.0) / 15.0, mod(packedLight, 16.0) / 15.0);
}

// Noise uses true-world modulo coordinates from the Mod, rather than the
// loader's rebased cameraPosition. Density and motion remain stable at +/-1000.
vec2 atmosphereWorldXZ(vec2 relative) {
    if (hasTerrainAtmosphere()) {
        return terrainFogHeader(1.0).yz + relative - terrainFogHeader(0.0).xy;
    }
    return cameraPosition.xz + relative;
}

vec4 sampleTerrainFog(vec2 relative, vec4 origin, vec4 metadata, out float coverage) {
    vec2 coordinate = (relative - origin.xy) / origin.z;
    vec2 border = min(coordinate, metadata.x - 1.0 - coordinate);
    coverage = smoothstep(0.0, 4.0, min(border.x, border.y)) * metadata.w;
    if (coverage <= 0.0) {
        return vec4(0.0);
    }
    vec2 lower = clamp(floor(coordinate), vec2(0.0), vec2(metadata.x - 2.0));
    vec2 f = clamp(coordinate - lower, 0.0, 1.0);
    vec4 a = terrainFogCell(lower, metadata.x);
    vec4 b = terrainFogCell(lower + vec2(1.0, 0.0), metadata.x);
    vec4 c = terrainFogCell(lower + vec2(0.0, 1.0), metadata.x);
    vec4 d = terrainFogCell(lower + vec2(1.0), metadata.x);
    coverage *= min(min(a.a, b.a), min(c.a, d.a));
    vec4 field = mix(mix(decodeTerrainFogCell(a), decodeTerrainFogCell(b), f.x),
                     mix(decodeTerrainFogCell(c), decodeTerrainFogCell(d), f.x), f.y);
    vec2 gradient = vec2(mix(b.r - a.r, d.r - c.r, f.y),
                         mix(c.r - a.r, d.r - b.r, f.x)) / origin.z;
    field.g = max(field.g, smoothstep(0.15, 1.0, length(gradient)) * 0.85);
    return field;
}

float terrainMistDensity(vec3 relative, vec4 field, float coverage, vec2 world) {
    float height = cameraPosition.y + relative.y - field.r;
    if (height < -0.5 || coverage <= 0.0 || field.g <= 0.0 || field.b <= 0.03) {
        return 0.0;
    }
    float rainFog = weatherRainAmount() * clamp(rainBiome, 0.0, 1.0) * RAIN_FOG_STRENGTH;
    // 只用静态、低对比度的大尺度分布。二维噪声不再随时间平移，避免竖向雾墙摆动。
    float broad = atmosphereNoise2(world / 128.0, 8.0);
    float dryLayer = GROUND_FOG_HEIGHT * mix(0.60, 1.25, broad);
    float rainLayer = clamp(GROUND_FOG_HEIGHT * 0.5, 2.0, 6.0);
    float layer = mix(dryLayer, rainLayer, clamp(rainFog, 0.0, 1.0));
    if (height >= layer * 3.0) {
        return 0.0;
    }
    // 雨量增加密度，不再把雾层抬到树冠；离地数个方块后连续衰减。
    float vertical = exp(-max(height, 0.0) / layer)
                   * smoothstep(-0.5, 1.0, height)
                   * (1.0 - smoothstep(layer * 1.5, layer * 3.0, height));
    float outdoors = smoothstep(0.03, 0.35, field.b);
    float weather = (0.22 + atmosphereTwilight() * 0.8 + getNightFactor() * 0.38)
                  * GROUND_FOG_STRENGTH + rainFog * 0.65;
    return vertical * outdoors * field.g * coverage * mix(0.82, 1.0, broad)
         * weather * FOG_DENSITY * 0.018;
}
#endif
