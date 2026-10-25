/* Hash complete current source/host images, then prepare new UV metadata.
 * Steady frames compare small keys; expensive palette classification is cached.
 */
/* RENDERTARGETS: 6 */
#include "/lib/world/ore_cache.glsl"
#include "/lib/world/ore_sources.glsl"
layout(location=0) out vec4 result;

void main() {
    int address = int(gl_FragCoord.x) - worldRegion(WORLD_REGION_ORE_PENDING).x;
    int ore = address / 3;
    int word = address % 3;
    result = vec4(0.0);
    if (ore >= 18) {
        if (address >= 60 && address <= 62) result = vec4(worldOreHostSize(address - 60), 0.0, 1.0);
        if (address == 63) result = vec4(textureSize(worldTextureAtlas, 0), 0.0, 1.0);
        return;
    }
    ivec4 descriptor = worldOreDescriptor(ore);
    if (descriptor.w != 917) return;
    WorldUv mapping = worldReadFaceMapping(colortex6, WORLD_TEXTURE_UV_START + descriptor.x);
    if (!mapping.valid) return;
    ivec2 atlas = textureSize(worldTextureAtlas, 0);
    ivec2 size = ivec2(round(vec2(mapping.u.x, mapping.v.y) * vec2(atlas)));
    ivec2 hostSize = worldOreHostSize(descriptor.y);
    if (size.x < 1 || size.x > 64 || size.x != size.y
        || hostSize.x < 1 || hostSize.x > 64 || hostSize.x != hostSize.y) return;
    vec2 origin = vec2(mapping.u.z, mapping.v.z);
    vec2 high = floor(origin * 1024.0) / 1024.0;
    if (word == 1) {
        result = vec4(high, mapping.u.x, mapping.v.y);
        return;
    }
    if (word == 2) {
        result = vec4(origin - high, float(size.x), 932.0);
        return;
    }
    ivec2 first = ivec2(round(origin * vec2(atlas)));
    uint hash = worldOreHash(2166136261u, uvec4(first, size));
    hash = worldOreHash(hash, uvec4(atlas, hostSize));
    for (int index = 0; index < 4096; index++) {
        if (index >= size.x * size.y) break;
        vec4 value = texelFetch(worldTextureAtlas, first + ivec2(index % size.x, index / size.x), 0);
        hash = worldOreHash(hash, uvec4(round(clamp(value, 0.0, 1.0) * 255.0)));
    }
    for (int index = 0; index < 4096; index++) {
        if (index >= hostSize.x * hostSize.y) break;
        hash = worldOreHash(hash, worldOreHostPixel(descriptor.y,
            ivec2(index % hostSize.x, index / hostSize.x)));
    }
    result = worldEncodeUint(hash);
}
