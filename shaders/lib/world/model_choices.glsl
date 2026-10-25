#ifndef SIMPLE_WORLD_MODEL_CHOICES_GLSL
#define SIMPLE_WORLD_MODEL_CHOICES_GLSL
#include "/lib/world/surface_table.glsl"
#include "/lib/world/choice_packing.glsl"

ivec4 worldModelChoiceRange(sampler2D staticData, int material) {
    if (!worldSurfaceMaterialValid(staticData, material)) return ivec4(0);
    ivec4 tables = worldSurfaceTables(staticData);
    int profile = worldSurfaceState(staticData, material).z;
    if (profile < 0 || profile >= tables.z) return ivec4(0);
    return ivec4(round(worldStaticTexel(staticData, tables.x + profile)));
}

WorldChoiceGroup worldModelChoiceGroup(sampler2D staticData, ivec4 range, int group) {
    int first = range.x + group * 3;
    return worldChoiceGroup(ivec4(round(worldStaticTexel(staticData, first))),
        ivec4(round(worldStaticTexel(staticData, first + 1))),
        ivec4(round(worldStaticTexel(staticData, first + 2))));
}

// A missing code remains unknown. Conditions may be evaluated only after every
// independent group has a validated choice for the observed block.
uint worldModelChoiceMask(sampler2D staticData, int material, int code, out bool valid) {
    ivec4 range = worldModelChoiceRange(staticData, material);
    valid = code >= 1 && code <= range.z;
    if (!valid) return 0u;
    uint mask = 0u;
    for (int index = 0; index < 6; index++) {
        if (index >= range.y) break;
        WorldChoiceGroup group = worldModelChoiceGroup(staticData, range, index);
        int choice = ((code - 1) / group.radix) % group.count;
        mask |= 1u << uint(group.choiceBit + choice);
    }
    return mask;
}
#endif
