#ifndef SIMPLE_WORLD_STATIC_GLSL
#define SIMPLE_WORLD_STATIC_GLSL
#include "/lib/world/coordinates.glsl"
#include "/lib/world/layout.glsl"

// Static model descriptors are separate from per-frame world observations.
// A state references a union of up to 32 model boxes; two bytes address a box.
ivec3 worldShapeDescriptor(sampler2D data, int material) {
    if (material < 0 || material >= 32768) return ivec3(0);
    int index = material * 2;
    ivec4 region = worldRegion(WORLD_REGION_STATES);
    ivec2 pixel = region.xy + ivec2(index % region.z, index / region.z);
    ivec4 record = ivec4(round(texelFetch(data, pixel, 0)));
    return ivec3((record.x + record.y * 256) * 2, record.z, record.w);
}

vec4 worldStaticTexel(sampler3D resource, int index) {
    return texelFetch(resource, ivec3(index % 64, (index / 64) % 64, index / 4096), 0);
}
#endif
