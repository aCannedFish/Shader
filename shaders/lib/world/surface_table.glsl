#ifndef SIMPLE_WORLD_SURFACE_TABLE_GLSL
#define SIMPLE_WORLD_SURFACE_TABLE_GLSL
#include "/lib/world/static.glsl"

const int WORLD_SURFACE_START = 294912;
const int WORLD_TEXTURE_UV_START = 180000;

// The immutable resource keeps core state/shape records stable, followed by a
// versioned surface directory. Its references remain full-precision integers.
ivec4 worldSurfaceHeader(sampler2D resource) {
    return ivec4(round(worldStaticTexel(resource, WORLD_SURFACE_START)));
}

ivec4 worldSurfaceTables(sampler2D resource) {
    return ivec4(round(worldStaticTexel(resource, WORLD_SURFACE_START + 1)));
}

bool worldSurfaceMaterialValid(sampler2D resource, int material) {
    ivec4 header = worldSurfaceHeader(resource);
    ivec4 format = ivec4(round(worldStaticTexel(resource, WORLD_SURFACE_START + 2)));
    return all(equal(format, ivec4(805, 2, 13, 3))) && material > 0 && material < header.y - header.x;
}

ivec4 worldSurfaceState(sampler2D resource, int material) {
    if (!worldSurfaceMaterialValid(resource, material)) return ivec4(0);
    ivec4 header = worldSurfaceHeader(resource);
    return ivec4(round(worldStaticTexel(resource, header.x + material)));
}

ivec2 worldSurfaceList(sampler2D resource, int material) {
    return worldSurfaceState(resource, material).xy;
}

ivec2 worldSurfaceReference(sampler2D resource, int address) {
    ivec4 header = worldSurfaceHeader(resource);
    vec4 words = worldStaticTexel(resource, header.z + address / 2);
    int component = (address % 2) * 2;
    return ivec2(round(vec2(words[component], words[component + 1])));
}

int worldSurfaceId(sampler2D resource, int address) {
    return worldSurfaceReference(resource, address).x >> 8;
}

int worldSurfaceHint(sampler2D resource, int address) {
    return worldSurfaceReference(resource, address).x & 255;
}
#endif
