#ifndef SIMPLE_WORLD_STATIC_GLSL
#define SIMPLE_WORLD_STATIC_GLSL
#include "/lib/world/coordinates.glsl"
#include "/lib/world/layout.glsl"
#include "/lib/world/definition.glsl"

vec4 worldStateRecord(sampler2D data, int material, int word) {
    if (material < 0 || material >= 32768) return vec4(0.0);
    int index = material * WORLD_STATE_STRIDE + word;
    ivec4 region = worldRegion(WORLD_REGION_STATES);
    return texelFetch(data, region.xy + ivec2(index % region.z, index / region.z), 0);
}

WorldDefinition worldReadDefinition(sampler2D data, int material) {
    return worldDecodeDefinition(worldStateRecord(data, material, 0),
        worldStateRecord(data, material, 1), worldStateRecord(data, material, 2));
}

ivec3 worldShapeDescriptor(sampler2D data, int material) {
    WorldDefinition definition = worldReadDefinition(data, material);
    return ivec3(definition.firstBox * WORLD_SHAPE_STRIDE,
        definition.boxCount, definition.legacy);
}

vec4 worldStaticTexel(sampler3D resource, int index) {
    int row = index / WORLD_STATIC_SIZE.x;
    return texelFetch(resource, ivec3(index % WORLD_STATIC_SIZE.x,
        row % WORLD_STATIC_SIZE.y, row / WORLD_STATIC_SIZE.y), 0);
}
#endif
