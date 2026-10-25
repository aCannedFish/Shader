#ifndef SIMPLE_WORLD_MODEL_OFFSET_GLSL
#define SIMPLE_WORLD_MODEL_OFFSET_GLSL
#include "/lib/world/surface_table.glsl"

struct WorldModelOffset {
    vec3 value;
    ivec3 code;
    bool valid;
};

int worldModelOffsetStart(sampler2D staticData, int material) {
    if (!worldSurfaceMaterialValid(staticData, material)) return -1;
    ivec4 tables = worldSurfaceTables(staticData);
    int profile = worldSurfaceState(staticData, material).w;
    if (profile < 0 || profile >= tables.w) return -1;
    return tables.y + profile * 13;
}

float worldModelOffsetValue(sampler2D staticData, int first, int axis, int code) {
    vec4 values = worldStaticTexel(staticData, first + 1 + axis * 4 + code / 4);
    return values[code % 4];
}

WorldModelOffset worldDecodeModelOffset(sampler2D staticData, int material, ivec3 code) {
    WorldModelOffset result = WorldModelOffset(vec3(0.0), code, false);
    int first = worldModelOffsetStart(staticData, material);
    if (first < 0) return result;
    ivec3 counts = ivec3(round(worldStaticTexel(staticData, first).xyz));
    if (any(lessThan(code, ivec3(0))) || any(greaterThanEqual(code, counts))) return result;
    for (int axis = 0; axis < 3; axis++) {
        result.value[axis] = worldModelOffsetValue(staticData, first, axis, code[axis]);
    }
    result.valid = true;
    return result;
}

// Clamped dripstone profiles are nonuniform. Search the exact values instead
// of inferring an evenly spaced offset or using the private world-origin seed.
WorldModelOffset worldFindModelOffset(sampler2D staticData, int material, vec3 displacement, float tolerance) {
    WorldModelOffset result = WorldModelOffset(vec3(0.0), ivec3(0), false);
    int first = worldModelOffsetStart(staticData, material);
    if (first < 0) return result;
    ivec3 counts = ivec3(round(worldStaticTexel(staticData, first).xyz));
    for (int axis = 0; axis < 3; axis++) {
        float error = 1e20;
        for (int code = 0; code < 16; code++) {
            if (code >= counts[axis]) break;
            float value = worldModelOffsetValue(staticData, first, axis, code);
            float difference = abs(value - displacement[axis]);
            if (difference < error) {
                error = difference;
                result.value[axis] = value;
                result.code[axis] = code;
            }
        }
        if (error > tolerance) return result;
    }
    result.valid = true;
    return result;
}
#endif
