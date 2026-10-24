#ifndef SIMPLE_WORLD_GLASS_CACHE_GLSL
#define SIMPLE_WORLD_GLASS_CACHE_GLSL
#include "/lib/world/light_selection.glsl"

ivec3 worldGlassOrigin(sampler2D data, bool previous) {
    ivec3 origin = previous ? worldLightOrigin(data, true) : worldReadOrigin(data, false);
    return origin + WORLD_FAR_SHAPE / 2 - ivec3(WORLD_GI_SIZE / 2);
}

ivec2 worldGlassCacheAddress(int light, ivec3 cell) {
    int side = WORLD_GI_SIZE + 2;
    int rows = (WORLD_GI_SIZE + 7) / 8;
    ivec2 base = worldRegion(WORLD_REGION_GLASS_TRANSFER).xy
        + ivec2(light % 8 * side * 8, light / 8 * side * rows);
    return base + worldVoxelAddress(cell, ivec3(WORLD_GI_SIZE), 1, 0);
}

// Filter only valid receiver samples; solid receiver cells cannot dilute a
// coloured window's transfer. A negative alpha records partial world knowledge.
vec3 worldPointGlassFilter(sampler2D data, int slot, WorldPosition receiver, vec3 normal) {
    ivec3 origin = worldGlassOrigin(data, false);
    vec3 point = vec3(receiver.block - origin) + receiver.fraction + normal * 0.35 - 0.5;
    if (any(lessThan(point, vec3(-0.5))) || any(greaterThan(point, vec3(float(WORLD_GI_SIZE) - 0.5)))) return vec3(1.0);
    vec3 bounded = clamp(point, vec3(0.0), vec3(float(WORLD_GI_SIZE - 1)));
    ivec3 first = ivec3(floor(bounded));
    vec3 fraction = fract(bounded);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int corner = 0; corner < 8; corner++) {
        ivec3 offset = ivec3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        ivec3 cell = min(first + offset, ivec3(WORLD_GI_SIZE - 1));
        vec4 sample = texelFetch(data, worldGlassCacheAddress(slot + 1, cell), 0);
        if (abs(sample.w) < 0.5) continue;
        vec3 weights = mix(vec3(1.0) - fraction, fraction, vec3(offset));
        float weight = weights.x * weights.y * weights.z;
        sum += sample.rgb * weight;
        total += weight;
    }
    return total > 0.00001 ? clamp(sum / total, vec3(0.0), vec3(1.0)) : vec3(1.0);
}
#endif
