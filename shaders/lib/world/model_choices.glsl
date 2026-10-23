#ifndef SIMPLE_WORLD_MODEL_CHOICES_GLSL
#define SIMPLE_WORLD_MODEL_CHOICES_GLSL
#include "/lib/world/surface_table.glsl"
#include "/lib/world/choice_packing.glsl"

ivec4 worldModelChoiceRange(sampler2D resource, int material) {
    if (!worldSurfaceMaterialValid(resource, material)) return ivec4(0);
    ivec4 tables = worldSurfaceTables(resource);
    int profile = worldSurfaceState(resource, material).z;
    if (profile < 0 || profile >= tables.z) return ivec4(0);
    return ivec4(round(worldStaticTexel(resource, tables.x + profile)));
}

WorldChoiceGroup worldModelChoiceGroup(sampler2D resource, ivec4 range, int group) {
    int first = range.x + group * 3;
    return worldChoiceGroup(ivec4(round(worldStaticTexel(resource, first))),
        ivec4(round(worldStaticTexel(resource, first + 1))),
        ivec4(round(worldStaticTexel(resource, first + 2))));
}

// A missing code remains unknown. Conditions may be evaluated only after every
// independent group has a validated choice for the observed block.
uint worldModelChoiceMask(sampler2D resource, int material, int code, out bool valid) {
    ivec4 range = worldModelChoiceRange(resource, material);
    valid = code >= 1 && code <= range.z;
    if (!valid) return 0u;
    uint mask = 0u;
    for (int index = 0; index < 6; index++) {
        if (index >= range.y) break;
        WorldChoiceGroup group = worldModelChoiceGroup(resource, range, index);
        int choice = ((code - 1) / group.radix) % group.count;
        mask |= 1u << uint(group.choiceBit + choice);
    }
    return mask;
}
#endif
