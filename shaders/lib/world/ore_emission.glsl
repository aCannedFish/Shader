/* Consume the current native-resolution mask. Anisotropic sprite UVs are
 * converted back to atlas coordinates before locating the cached mineral pixel.
 */
#ifndef SIMPLE_WORLD_ORE_EMISSION_GLSL
#define SIMPLE_WORLD_ORE_EMISSION_GLSL
#include "/lib/world/ore_cache.glsl"
#include "/lib/world/atlas_uv.glsl"
uniform vec4 spriteBounds;

vec3 worldOreEmission(float blockId, vec2 textureUv, vec3 textureColour, ivec2 boundSize) {
    int ore = int(round(blockId)) - 400;
    vec4 metadata = worldOreMetadata(ore, 2, false);
    if (metadata.w != 932.0) return vec3(0.0);
    vec4 bounds = worldOreMetadata(ore, 1, false);
    vec2 atlasUv = worldAtlasUv(textureUv, spriteBounds, boundSize, atlasSize);
    vec2 local = (atlasUv - bounds.xy - metadata.xy) / bounds.zw;
    if (any(lessThan(local, vec2(-0.001))) || any(greaterThan(local, vec2(1.001)))) return vec3(0.0);
    int side = int(round(metadata.z));
    ivec2 pixel = clamp(ivec2(floor(local * float(side))), ivec2(0), ivec2(side - 1));
    float mask = texelFetch(colortex6, worldOreMaskPixel(ore, pixel), 0).r;
    vec3 pigment = toLinearSpace(textureColour);
    pigment /= max(max(pigment.r, max(pigment.g, pigment.b)), 0.035);
    float strength = ore < 2 ? 0.0 : ore < 6 ? 0.55 : 0.85;
    return pigment * mask * strength * ORE_GLOW_STRENGTH;
}
#endif
