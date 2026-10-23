#ifndef SIMPLE_WORLD_LOOKUP_GLSL
#define SIMPLE_WORLD_LOOKUP_GLSL
#include "/lib/world/coordinates.glsl"
#include "/lib/world/types.glsl"
#include "/lib/world/capture_layout.glsl"

ivec3 worldReadOrigin(sampler2D data, bool nearField) {
    ivec2 header = worldRegion(WORLD_REGION_HEADER).xy;
    int start = nearField ? 2 : 5;
    return ivec3(worldDecodeInt(texelFetch(data, header + ivec2(start, 0), 0)),
        worldDecodeInt(texelFetch(data, header + ivec2(start + 1, 0), 0)),
        worldDecodeInt(texelFetch(data, header + ivec2(start + 2, 0), 0)));
}

uint worldReadGeneration(sampler2D data) {
    ivec2 header = worldRegion(WORLD_REGION_HEADER).xy;
    return worldDecodeUint(texelFetch(data, header + ivec2(1, 0), 0));
}

WorldSample worldReadCell(sampler2D data, WorldPosition position, bool nearField) {
    uint generation = worldReadGeneration(data);
    ivec2 header = worldRegion(WORLD_REGION_HEADER).xy;
    if (worldDecodeUint(texelFetch(data, header, 0)) != WORLD_LAYOUT_SIGNATURE) {
        return worldUnknown(generation);
    }
    ivec3 shape = nearField ? WORLD_NEAR_SHAPE : WORLD_FAR_SHAPE;
    ivec3 origin = worldReadOrigin(data, nearField);
    ivec3 cell = worldGridCell(position, origin, nearField ? 2 : 1);
    if (!worldCellValid(cell, shape)) return worldUnknown(generation);
    ivec2 pixel = worldVoxelAddress(cell, shape, 0, 0);
    int materialRegion = nearField ? WORLD_REGION_NEAR_MATERIAL : WORLD_REGION_FAR_MATERIAL;
    int opticsRegion = nearField ? WORLD_REGION_NEAR_OPTICS : WORLD_REGION_FAR_OPTICS;
    vec4 material = texelFetch(data, worldAtlasPixel(materialRegion, pixel), 0);
    ivec4 optics = ivec4(round(texelFetch(data, worldAtlasPixel(opticsRegion, pixel), 0)));
    if (optics.w == WORLD_UNKNOWN) return worldUnknown(generation);
    int packedLight = int(round(material.w));
    return WorldSample(optics.w, optics.x + optics.y * 256, generation,
        max(material.rgb, vec3(0.0)), vec2(packedLight % 16, packedLight / 16) / 15.0, 1.0);
}

WorldSample worldRead(sampler2D data, WorldPosition position) {
    WorldSample nearSample = worldReadCell(data, position, true);
    if (nearSample.state != WORLD_UNKNOWN) return nearSample;
    return worldReadCell(data, position, false);
}
#endif
