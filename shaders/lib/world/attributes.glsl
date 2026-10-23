#ifndef SIMPLE_WORLD_ATTRIBUTES_GLSL
#define SIMPLE_WORLD_ATTRIBUTES_GLSL
#include "/lib/world/lookup.glsl"
#include "/lib/world/model_choices.glsl"
#include "/lib/world/model_offset.glsl"

struct WorldAttributes {
    WorldPosition owner;
    vec3 tint;
    WorldModelOffset offset;
    uint choices;
    bool modelValid;
    bool tintValid;
};

// Four exact 11-bit half-float words store 24 tint bits, 17 joint-pose bits
// and three validity flags. Unknown fields never acquire a default model.
vec4 worldEncodeAttributes(vec3 tint, int pose, bool offsetValid, bool modelValid, bool tintValid) {
    uvec3 rgb = uvec3(round(clamp(tint, vec3(0.0), vec3(1.0)) * 255.0));
    uint colour = rgb.r | (rgb.g << 8u) | (rgb.b << 16u);
    uint code = uint(pose);
    return vec4(colour & 2047u, (colour >> 11u) & 2047u,
        (colour >> 22u) | ((code & 511u) << 2u),
        (code >> 9u) | (uint(offsetValid) << 8u)
            | (uint(modelValid) << 9u) | (uint(tintValid) << 10u));
}

WorldAttributes worldReadAttributes(sampler2D data, sampler2D resource, WorldPosition owner, int material) {
    WorldAttributes result = WorldAttributes(owner, vec3(1.0),
        WorldModelOffset(vec3(0.0), ivec3(0), false), 0u, false, false);
    ivec3 cell = worldGridCell(owner, worldReadOrigin(data, false), 1);
    if (!worldCellValid(cell, WORLD_FAR_SHAPE) || !worldSurfaceMaterialValid(resource, material)) return result;
    ivec2 pixel = worldAtlasPixel(WORLD_REGION_FAR_ATTRIBUTES,
        worldVoxelAddress(cell, WORLD_FAR_SHAPE, 0, 0));
    uvec4 words = uvec4(round(texelFetch(data, pixel, 0)));
    uint colour = words.x | (words.y << 11u) | ((words.z & 3u) << 22u);
    result.tint = vec3(colour & 255u, (colour >> 8u) & 255u, (colour >> 16u) & 255u) / 255.0;
    int pose = int((words.z >> 2u) | ((words.w & 255u) << 9u));
    int first = worldModelOffsetStart(resource, material);
    ivec3 counts = ivec3(round(worldStaticTexel(resource, first).xyz));
    int product = counts.x * counts.y * counts.z;
    if (product <= 0) return result;
    int offset = pose % product;
    ivec3 code = ivec3(offset % counts.x, (offset / counts.x) % counts.y,
        offset / (counts.x * counts.y));
    result.offset = worldDecodeModelOffset(resource, material, code);
    result.offset.valid = result.offset.valid && (words.w & 256u) != 0u;
    bool valid;
    result.choices = worldModelChoiceMask(resource, material, pose / product + 1, valid);
    result.modelValid = valid && (words.w & 512u) != 0u;
    result.tintValid = (words.w & 1024u) != 0u;
    return result;
}

// Conditions are ORs of independent choices; -1 marks a fixed face. Without
// complete observations, conditional geometry remains uncertain.
bool worldModelFaceEnabled(ivec2 reference, WorldAttributes attributes) {
    return reference.y < 0 || (attributes.modelValid && (uint(reference.y) & attributes.choices) != 0u);
}
#endif
