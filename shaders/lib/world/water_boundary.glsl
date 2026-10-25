/* Keep the resolved water boundary attached to neighbouring solids. The field
 * damps geometric displacement and its matching shading normal near contact;
 * it never changes water coverage or substitutes a darker shoreline colour.
 */
#ifndef SIMPLE_WORLD_WATER_BOUNDARY_GLSL
#define SIMPLE_WORLD_WATER_BOUNDARY_GLSL
#include "/lib/world/storage.glsl"
#include "/lib/world/lookup.glsl"

float worldWaterShoreWeight(vec3 relative, vec3 camera) {
    WorldPosition position = worldPosition(relative, camera);
    float distance = 2.0;
    for (int z = -1; z <= 1; z++) {
        for (int x = -1; x <= 1; x++) {
            ivec3 offset = ivec3(x, 0, z);
            WorldSample neighbour = worldReadCell(colortex6,
                WorldPosition(position.block + offset, vec3(0.5)), false);
            if (neighbour.state != WORLD_SURFACE && neighbour.state != WORLD_TRANSMISSION) continue;
            vec2 low = vec2(x, z) - position.fraction.xz;
            vec2 separation = max(max(low, -low - 1.0), vec2(0.0));
            distance = min(distance, length(separation));
        }
    }
    return smoothstep(0.0, 0.6, distance);
}
#endif
