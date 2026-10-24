/* Logical solar coordinates remain independent of the physical capture atlas.
 * Rasterization and every depth/colour consumer share this mapping.
 */
#ifndef SIMPLE_WORLD_SOLAR_GLSL
#define SIMPLE_WORLD_SOLAR_GLSL
#include "/lib/world/capture_layout.glsl"

vec2 worldSolarAtlasUv(vec2 logical) {
    vec2 size = vec2(textureSize(shadowtex0, 0));
    vec2 scale = size / float(WORLD_CAPTURE_SIDE);
    vec2 low = vec2(WORLD_CAPTURE_SOLAR.xy) * scale;
    vec2 span = vec2(WORLD_CAPTURE_SOLAR.zw) * scale;
    return (low + clamp(logical, 0.5 / span, 1.0 - 0.5 / span) * span) / size;
}

float worldSolarDepth(sampler2D field, vec2 logical) {
    return texture(field, worldSolarAtlasUv(logical)).r;
}

vec4 worldSolarColour(sampler2D field, vec2 logical) {
    return texture(field, worldSolarAtlasUv(logical));
}
#endif
