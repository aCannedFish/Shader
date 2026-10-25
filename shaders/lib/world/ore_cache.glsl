/* Active-atlas ore masks use the observed native sprite mapping. Metadata is
 * published only after its masks, so a resource change cannot expose old bits
 * with new UVs. Every source pixel retains its native pixel-art boundary.
 */
#ifndef SIMPLE_WORLD_ORE_CACHE_GLSL
#define SIMPLE_WORLD_ORE_CACHE_GLSL
#include "/lib/world/storage.glsl"
#include "/lib/world/surface_uv.glsl"

ivec2 worldOreMetadataPixel(int ore, int word, bool pending) {
    ivec4 region = worldRegion(pending ? WORLD_REGION_ORE_PENDING : WORLD_REGION_ORE_METADATA);
    return region.xy + ivec2(ore * 3 + word, 0);
}

vec4 worldOreMetadata(int ore, int word, bool pending) {
    return texelFetch(colortex6, worldOreMetadataPixel(ore, word, pending), 0);
}

ivec2 worldOreMaskPixel(int ore, ivec2 pixel) {
    ivec4 region = worldRegion(WORLD_REGION_ORE_MASKS);
    int index = ore * 4096 + pixel.y * 64 + pixel.x;
    return region.xy + ivec2(index % region.z, index / region.z);
}

ivec4 worldOreDescriptor(int ore) {
    vec4 descriptor = worldStaticTexel(noisetex, 172768 + ore);
    return descriptor.w == 917.0 ? ivec4(round(descriptor)) : ivec4(-1);
}

vec2 worldOreAtlasUv(int ore, vec2 localUv, bool pending) {
    vec4 bounds = worldOreMetadata(ore, 1, pending);
    vec2 residual = worldOreMetadata(ore, 2, pending).xy;
    return bounds.xy + residual + localUv * bounds.zw;
}
#endif
