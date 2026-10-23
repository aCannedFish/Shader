#ifndef SIMPLE_WORLD_DEBUG_GLSL
#define SIMPLE_WORLD_DEBUG_GLSL
#include "/lib/world/lookup.glsl"

// Side-by-side horizontal slices expose near/far knowledge without asking a
// lighting or reflection fallback to stand in for missing geometry.
vec3 worldDebugSlice(sampler2D data, vec2 uv, vec3 camera, int mode) {
    bool nearField = uv.x < 0.5;
    uv.x = fract(uv.x * 2.0);
    ivec3 shape = nearField ? WORLD_NEAR_SHAPE : WORLD_FAR_SHAPE;
    int rate = nearField ? 2 : 1;
    ivec3 origin = worldReadOrigin(data, nearField);
    int y = int(floor((camera.y - 6.0) * float(rate))) - origin.y;
    ivec3 cell = ivec3(int(uv.x * float(shape.x)), y, int(uv.y * float(shape.z)));
    if (!worldCellValid(cell, shape)) return vec3(0.8, 0.0, 0.0);
    ivec2 address = worldVoxelAddress(cell, shape, 0, 0);
    int opticsRegion = nearField ? WORLD_REGION_NEAR_OPTICS : WORLD_REGION_FAR_OPTICS;
    int materialRegion = nearField ? WORLD_REGION_NEAR_MATERIAL : WORLD_REGION_FAR_MATERIAL;
    vec4 optics = texelFetch(data, worldAtlasPixel(opticsRegion, address), 0);
    vec3 albedo = texelFetch(data, worldAtlasPixel(materialRegion, address), 0).rgb;
    bool unknown = optics.w < 0.5;
    bool changed = optics.z >= 8.0;
    if (mode == 3 && changed) return vec3(1.0, 0.55, 0.04);
    if (unknown) return vec3(0.20, 0.035, 0.27);
    if (mode == 2) return vec3(0.15, 0.70, 0.38);
    if (mode == 3) return vec3(0.08, 0.25, 0.18);
    if (mode == 4) {
        uint epoch = worldReadGeneration(data);
        float hue = float(epoch % 97u) / 97.0;
        return 0.35 + 0.30 * cos(vec3(0.0, 2.1, 4.2) + hue * 6.2831853);
    }
    if (optics.w == float(WORLD_WATER)) return vec3(0.05, 0.30, 0.8);
    if (optics.w == float(WORLD_TRANSMISSION)) return vec3(0.25, 0.75, 0.85);
    return max(pow(max(albedo, vec3(0.0)), vec3(1.0 / 2.2)), vec3(0.06));
}

vec3 worldDebugView(sampler2D data, vec2 uv, vec3 camera, int mode) {
    if (uv.y > 0.97) {
        // The top strip exposes all 32 epoch bits, least significant on the
        // left. The readback ledger also records their ordinary integer value.
        uint epoch = worldReadGeneration(data);
        uint bit = uint(min(int(uv.x * 32.0), 31));
        return ((epoch >> bit) & 1u) != 0u ? vec3(1.0, 0.6, 0.1) : vec3(0.03);
    }
    return worldDebugSlice(data, uv, camera, mode);
}
#endif
