#ifndef SIMPLE_WORLD_TRANSMISSION_GLSL
#define SIMPLE_WORLD_TRANSMISSION_GLSL
#include "/lib/world/glass_query.glsl"

struct WorldTransmission {
    vec3 value;
    bool complete;
};

// Integrate known glass along a finite light segment. Unknown intervals remain
// explicit: the result is then an upper bound on transmission, not proof of an
// empty segment. Independent opaque visibility comes from the light's cube map.
WorldTransmission worldTraceGlassSegment(sampler2D data, sampler2D staticData,
    WorldPosition start, WorldPosition end, bool ignoreEndCell) {
    WorldTransmission result = WorldTransmission(vec3(1.0), true);
    vec3 delta = vec3(end.block - start.block) + end.fraction - start.fraction;
    float distance = length(delta);
    if (distance < 0.00001) return result;
    vec3 direction = delta / distance;
    ivec3 cell = start.block;
    ivec3 step = ivec3(sign(direction));
    vec3 next = vec3(1e20);
    vec3 interval = vec3(1e20);
    for (int axis = 0; axis < 3; axis++) {
        if (abs(direction[axis]) < 1e-8) continue;
        next[axis] = ((direction[axis] > 0.0 ? 1.0 : 0.0) - start.fraction[axis]) / direction[axis];
        interval[axis] = 1.0 / abs(direction[axis]);
    }
    ivec3 fieldOrigin = worldReadOrigin(data, false);
    float enter = 0.0;
    for (int index = 0; index < 128; index++) {
        // The emitter's own block is excluded, as in the original renderer.
        if (ignoreEndCell && all(equal(cell, end.block))) return result;
        float leave = min(distance, min(next.x, min(next.y, next.z)));
        ivec3 fieldCell = cell - fieldOrigin;
        if (!worldCellValid(fieldCell, WORLD_FAR_SHAPE)) {
            result.complete = false;
        } else {
            ivec2 pixel = worldAtlasPixel(WORLD_REGION_FAR_OPTICS,
                worldVoxelAddress(fieldCell, WORLD_FAR_SHAPE, 0, 0));
            ivec4 optics = ivec4(round(texelFetch(data, pixel, 0)));
            if (optics.w == WORLD_UNKNOWN) result.complete = false;
            if (optics.w == WORLD_SURFACE && (worldReadDefinition(data, optics.x + optics.y * 256).flags & 8) != 0) {
                result.complete = false;
            }
            if (optics.w == WORLD_TRANSMISSION) {
                int material = optics.x + optics.y * 256;
                WorldDefinition definition = worldReadDefinition(data, material);
                if (max(definition.absorption.r, max(definition.absorption.g, definition.absorption.b)) > 0.0) {
                    WorldPosition owner = WorldPosition(cell, vec3(0.5));
                    WorldAttributes attributes = worldReadAttributes(data, staticData, owner, material);
                    vec3 localOrigin = vec3(start.block - cell) + start.fraction;
                    bool valid;
                    vec3 transfer = worldQueryGlassTransmission(data, material, attributes,
                        localOrigin, direction, enter, leave, valid);
                    if (valid) result.value *= transfer;
                    else result.complete = false;
                }
            }
        }
        if (leave >= distance) return result;
        float crossing = min(next.x, min(next.y, next.z));
        for (int axis = 0; axis < 3; axis++) {
            if (next[axis] <= crossing + 0.000001) {
                cell[axis] += step[axis];
                next[axis] += interval[axis];
            }
        }
        enter = leave;
    }
    result.complete = false;
    return result;
}
WorldTransmission worldTraceGlass(sampler2D data, sampler2D staticData, WorldPosition start, WorldPosition end) {
    return worldTraceGlassSegment(data, staticData, start, end, true);
}
#endif
