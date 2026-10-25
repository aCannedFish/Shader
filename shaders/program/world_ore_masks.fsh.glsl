/* Reclassify native source pixels only when their complete resource key changes.
 * Host-palette matches always win, preventing the rock from becoming emissive.
 */
/* RENDERTARGETS: 6 */
#include "/lib/world/ore_cache.glsl"
#include "/lib/world/ore_sources.glsl"
layout(location=0) out vec4 result;

void main() {
    ivec4 region = worldRegion(WORLD_REGION_ORE_MASKS);
    ivec2 local = ivec2(gl_FragCoord.xy) - region.xy;
    int index = local.x + local.y * region.z;
    int ore = index / 4096;
    ivec2 pixel = ivec2(index % 64, (index / 64) % 64);
    result = vec4(0.0);
    if (ore >= 18) return;
    vec4 info = worldOreMetadata(ore, 2, true);
    int side = int(round(info.z));
    if (info.w != 932.0 || any(greaterThanEqual(pixel, ivec2(side)))) return;
    if (worldOreMetadata(ore, 2, false).w == 932.0
        && all(equal(worldOreMetadata(ore, 0, true), worldOreMetadata(ore, 0, false)))) {
        result = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0);
        return;
    }
    vec2 uv = worldOreAtlasUv(ore, (vec2(pixel) + 0.5) / float(side), true);
    ivec2 atlasPixel = ivec2(floor(uv * vec2(textureSize(worldTextureAtlas, 0))));
    uvec4 colour = uvec4(round(clamp(texelFetch(worldTextureAtlas, atlasPixel, 0), 0.0, 1.0) * 255.0));
    int maximum = int(max(colour.r, max(colour.g, colour.b)));
    int minimum = int(min(colour.r, min(colour.g, colour.b)));
    if (colour.a < 128u || (ore < 2 ? maximum > 76 : ore == 17 ? minimum < 105 : maximum - minimum <= 12)) return;
    int host = worldOreDescriptor(ore).y;
    ivec2 hostSize = worldOreHostSize(host);
    for (int palette = 0; palette < 4096; palette++) {
        if (palette >= hostSize.x * hostSize.y) break;
        ivec3 rock = ivec3(worldOreHostPixel(host, ivec2(palette % hostSize.x, palette / hostSize.x)).rgb);
        ivec3 difference = abs(ivec3(colour.rgb) - rock);
        if (max(difference.r, max(difference.g, difference.b)) <= 8) return;
    }
    result = vec4(1.0, 0.0, 0.0, 1.0);
}
