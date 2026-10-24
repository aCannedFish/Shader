#ifndef SIMPLE_WORLD_GI_GLSL
#define SIMPLE_WORLD_GI_GLSL
#include "/lib/world/light_selection.glsl"

#ifndef GI_BOUNCES
#define GI_BOUNCES 4
#endif
#ifndef GI_PROPAGATION_STEPS
#define GI_PROPAGATION_STEPS 8
#endif
#ifndef GI_WORK_PER_FRAME
#define GI_WORK_PER_FRAME 4
#endif
#ifndef GI_REFLECTANCE
#define GI_REFLECTANCE 0.55
#endif
#ifndef GI_STRENGTH
#define GI_STRENGTH 0.75
#endif

struct WorldGiState {
    int bounce;
    int iteration;
    ivec3 origin;
    ivec3 publishedOrigin;
    bool ready;
    bool valid;
};

vec4 worldGiHeader(sampler2D data, int index) {
    return texelFetch(data, worldRegion(WORLD_REGION_GI_CONTROL).xy + ivec2(index, 0), 0);
}

ivec3 worldGiCurrentOrigin(sampler2D data) {
    return worldReadOrigin(data, false) + WORLD_FAR_SHAPE / 2 - ivec3(WORLD_GI_SIZE / 2);
}

ivec3 worldGiStoredOrigin(sampler2D data, int first) {
    return ivec3(worldDecodeInt(worldGiHeader(data, first)), worldDecodeInt(worldGiHeader(data, first + 1)),
        worldDecodeInt(worldGiHeader(data, first + 2)));
}

WorldGiState worldGiState(sampler2D data) {
    vec4 header = worldGiHeader(data, 0);
    bool valid = header.x == 1061.0 && worldDecodeUint(worldGiHeader(data, 7)) == worldReadGeneration(data);
    ivec3 origin = worldGiCurrentOrigin(data);
    return valid ? WorldGiState(int(round(header.y)), int(round(header.z)),
        worldGiStoredOrigin(data, 1), worldGiStoredOrigin(data, 4), header.w > 0.5, true)
        : WorldGiState(0, 0, origin, origin, false, false);
}

ivec2 worldGiAddress(int region, ivec3 cell, int band) {
    return worldRegion(region).xy + worldVoxelAddress(cell, ivec3(WORLD_GI_SIZE), 1, band);
}

vec4 worldGiCoefficient(sampler2D data, int region, ivec3 cell, int band) {
    if (!worldCellValid(cell, ivec3(WORLD_GI_SIZE))) return vec4(0.0);
    return texelFetch(data, worldGiAddress(region, cell, band), 0);
}

// Padded slices let the texture unit interpolate X/Y without crossing another
// field. Two slice reads supply continuous Z, for six reads across RGB SH.
vec4 worldGiFilteredCoefficient(sampler2D data, vec3 position, int band) {
    vec3 p = clamp(position, vec3(0.0), vec3(float(WORLD_GI_SIZE - 1)));
    ivec3 first = ivec3(floor(p));
    ivec3 second = ivec3(first.xy, min(first.z + 1, WORLD_GI_SIZE - 1));
    vec2 size = vec2(textureSize(data, 0));
    vec2 within = fract(p.xy) + 0.5;
    vec2 a = (vec2(worldGiAddress(WORLD_REGION_GI_PUBLISHED, first, band)) + within) / size;
    vec2 b = (vec2(worldGiAddress(WORLD_REGION_GI_PUBLISHED, second, band)) + within) / size;
    return mix(textureLod(data, a, 0.0), textureLod(data, b, 0.0), fract(p.z));
}

// Coefficients and evaluation bases match the previous companion renderer.
vec4 worldGiLobe(vec3 direction) {
    return vec4(0.886227, direction * 1.023327);
}

vec3 worldGiRadiance(sampler2D data, int region, ivec3 cell, vec3 direction) {
    vec4 basis = vec4(0.282095, direction * 0.488603);
    return max(vec3(dot(worldGiCoefficient(data, region, cell, 0), basis),
        dot(worldGiCoefficient(data, region, cell, 1), basis),
        dot(worldGiCoefficient(data, region, cell, 2), basis)), vec3(0.0));
}

vec3 worldGiIrradiance(sampler2D data, int region, ivec3 cell, vec3 direction) {
    vec4 basis = worldGiLobe(direction);
    return max(vec3(dot(worldGiCoefficient(data, region, cell, 0), basis),
        dot(worldGiCoefficient(data, region, cell, 1), basis),
        dot(worldGiCoefficient(data, region, cell, 2), basis)), vec3(0.0));
}

// Only published fields are visible to surface lighting. The working origin
// can remain frozen across ordinary camera shifts until its cycle completes.
vec3 worldIndirectLight(sampler2D data, WorldPosition receiver, vec3 normal) {
    WorldGiState state = worldGiState(data);
    if (!state.ready || GI_BOUNCES == 0) return vec3(0.0);
    vec3 position = vec3(receiver.block - state.publishedOrigin) + receiver.fraction + normal * 0.65 - 0.5;
    vec3 border = min(position + 0.5, vec3(float(WORLD_GI_SIZE) - 0.5) - position);
    float weight = smoothstep(0.0, 2.0, min(border.x, min(border.y, border.z)));
    if (weight <= 0.0) return vec3(0.0);
    vec3 irradiance = vec3(0.0);
    vec4 basis = vec4(0.886227, -normal * 1.023327);
    for (int band = 0; band < 3; band++) {
        vec4 coefficient = worldGiFilteredCoefficient(data, position, band);
        irradiance[band] = max(dot(coefficient, basis), 0.0);
    }
    return irradiance * GI_STRENGTH * weight;
}
#endif
