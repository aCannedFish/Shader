#ifndef SIMPLE_WORLD_GLASS_QUERY_GLSL
#define SIMPLE_WORLD_GLASS_QUERY_GLSL
#include "/lib/world/shapes.glsl"
#include "/lib/world/static.glsl"
#include "/lib/world/attributes.glsl"

// Integrate the union of actual pane/connection volumes. Internal boundaries
// and overlapping model parts must not absorb the same water-free path twice.
// This path is limited to fixed glass geometry; unresolved choices stay unknown.
float worldGlassPathLength(sampler2D data, int material, WorldAttributes attributes,
    vec3 origin, vec3 direction, float minimum, float maximum) {
    WorldDefinition definition = worldReadDefinition(data, material);
    if (definition.alphaType != 2 || !attributes.offset.valid
        || !attributes.modelValid || (definition.flags & 16) != 0) return -1.0;
    ivec4 region = worldRegion(WORLD_REGION_SHAPES);
    origin -= attributes.offset.value;
    float cursor = minimum;
    float total = 0.0;
    for (int segment = 0; segment < 64; segment++) {
        float start = maximum;
        float end = maximum;
        for (int index = 0; index < 64; index++) {
            if (index >= definition.boxCount) break;
            WorldModelPart part = worldShapePart(data, definition.firstBox * WORLD_SHAPE_STRIDE,
                index, region.z, WORLD_SHAPE_STRIDE, region.xy);
            WorldBoxInterval interval = worldBoxInterval(worldPartLocalPoint(part, origin),
                worldPartLocalVector(part, direction), part.low, part.high);
            float enter = max(interval.enter, cursor);
            float leave = min(interval.leave, maximum);
            if (!interval.valid || leave <= cursor || leave <= enter) continue;
            if (enter < start) {
                start = enter;
                end = leave;
            }
        }
        if (start >= maximum) break;
        // Expand only the current connected interval before finding the next.
        for (int merge = 0; merge < 64; merge++) {
            if (merge >= definition.boxCount) break;
            float previous = end;
            for (int index = 0; index < 64; index++) {
                if (index >= definition.boxCount) break;
                WorldModelPart part = worldShapePart(data, definition.firstBox * WORLD_SHAPE_STRIDE,
                    index, region.z, WORLD_SHAPE_STRIDE, region.xy);
                WorldBoxInterval interval = worldBoxInterval(worldPartLocalPoint(part, origin),
                    worldPartLocalVector(part, direction), part.low, part.high);
                if (interval.valid && interval.enter <= end + 0.00001 && interval.leave > start) {
                    end = min(max(end, interval.leave), maximum);
                }
            }
            if (end <= previous) break;
        }
        total += end - start;
        cursor = end;
        if (cursor >= maximum) break;
    }
    return total;
}

vec3 worldQueryGlassTransmission(sampler2D data, int material, WorldAttributes attributes,
    vec3 origin, vec3 direction, float minimum, float maximum, out bool valid) {
    float pathLength = worldGlassPathLength(data, material, attributes, origin, direction, minimum, maximum);
    valid = pathLength >= 0.0;
    if (!valid) return vec3(1.0);
    WorldDefinition definition = worldReadDefinition(data, material);
    return exp(-definition.absorption * pathLength);
}
#endif
