#ifndef SIMPLE_WORLD_HUE_GLSL
#define SIMPLE_WORLD_HUE_GLSL
#include "/lib/world/lookup.glsl"

vec4 worldHueCell(sampler2D data, ivec3 cell) {
    if (!worldCellValid(cell, WORLD_FAR_SHAPE)) return vec4(0.0);
    return texelFetch(data, worldAtlasPixel(WORLD_REGION_HUE,
        worldVoxelAddress(cell, WORLD_FAR_SHAPE, 1, 0)), 0);
}

// A stores original source level and propagated remaining level as two nibbles.
// Colour is linear and normalized separately from the native light-field energy.
vec4 worldHue(sampler2D data, WorldPosition point) {
    ivec3 origin = worldReadOrigin(data, false);
    vec3 position = vec3(point.block - origin) + point.fraction - 0.5;
    ivec3 first = ivec3(floor(position));
    vec3 fraction = fract(position);
    vec3 colour = vec3(0.0);
    float emission = 0.0;
    float total = 0.0;
    for (int corner = 0; corner < 8; corner++) {
        ivec3 offset = ivec3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        vec4 hue = worldHueCell(data, first + offset);
        int metadata = int(round(hue.a));
        if (metadata < 16) continue;
        vec3 weights = mix(vec3(1.0) - fraction, fraction, vec3(offset));
        float weight = weights.x * weights.y * weights.z;
        colour += hue.rgb * weight;
        emission += float(metadata & 15) * weight;
        total += weight;
    }
    return total > 0.00001 ? vec4(colour / total, emission / total) : vec4(0.0);
}
#endif
