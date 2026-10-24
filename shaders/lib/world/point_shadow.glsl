#ifndef SIMPLE_WORLD_POINT_SHADOW_GLSL
#define SIMPLE_WORLD_POINT_SHADOW_GLSL
#include "/lib/world/light_selection.glsl"
#include "/lib/world/coverage.glsl"

ivec2 worldShadowLightPixel(int record, bool previous) {
    return previous ? worldPreviousLightPixel(record) : worldLightTablePixel(record);
}

bool worldShadowLightValid(sampler2D data, int slot, bool previous) {
    return texelFetch(data, worldShadowLightPixel(WORLD_LIGHT_HEADER_SIZE + slot * 4, previous), 0).w > 0.0;
}

bool worldShadowLightMapped(sampler2D data, int slot, bool previous) {
    return texelFetch(data, worldShadowLightPixel(WORLD_LIGHT_HEADER_SIZE + slot * 4 + 3, previous), 0).w > 0.5;
}

// New sources take precedence over the rotating refresh set. The same decision
// is used by capture, publication and cache renewal; no CPU timer or GI progress
// participates in direct-shadow availability.
bool worldPointShadowScheduledCandidate(sampler2D data, int slot, int frame, bool previous) {
    vec4 header = texelFetch(data, worldShadowLightPixel(0, previous), 0);
    if (header.x != 905.0 || worldDecodeInt(texelFetch(data, worldShadowLightPixel(1, previous), 0)) != frame - 1) return false;
    if (!worldShadowLightValid(data, slot, previous)) return false;
    int unmapped = 0;
    int unmappedBefore = 0;
    int dirtyCount = 0;
    int dirtyBefore = 0;
    int clean = 0;
    int cleanBefore = 0;
    for (int index = 0; index < WORLD_POINT_LIGHT_COUNT; index++) {
        if (!worldShadowLightValid(data, index, previous)) continue;
        bool mapped = worldShadowLightMapped(data, index, previous);
        bool dirty = texelFetch(data, worldShadowLightPixel(WORLD_LIGHT_HEADER_SIZE + index * 4 + 3, previous), 0).z > 0.5;
        if (!mapped) {
            unmapped++;
            if (index < slot) unmappedBefore++;
        } else if (dirty) {
            dirtyCount++;
            if (index < slot) dirtyBefore++;
        } else {
            clean++;
            if (index < slot) cleanBefore++;
        }
    }
    if (!worldShadowLightMapped(data, slot, previous)) return unmappedBefore < WORLD_POINT_SHADOW_UPDATES;
    bool dirty = texelFetch(data, worldShadowLightPixel(WORLD_LIGHT_HEADER_SIZE + slot * 4 + 3, previous), 0).z > 0.5;
    if (dirty) return unmapped + dirtyBefore < WORLD_POINT_SHADOW_UPDATES;
    int remaining = min(max(WORLD_POINT_SHADOW_UPDATES - unmapped - dirtyCount, 0), 3);
    if (remaining == 0 || clean == 0) return false;
    int first = (frame * remaining) % clean;
    return (cleanBefore - first + clean) % clean < min(remaining, clean);
}

uvec2 worldPointShadowMask(sampler2D data, int frame, bool previous) {
    vec4 header = texelFetch(data, worldShadowLightPixel(0, previous), 0);
    int sourceFrame = worldDecodeInt(texelFetch(data, worldShadowLightPixel(1, previous), 0));
    if (header.x != 905.0 || sourceFrame != frame - 1) return uvec2(0u);
    return uvec2(worldDecodeUint(texelFetch(data, worldShadowLightPixel(6, previous), 0)),
        worldDecodeUint(texelFetch(data, worldShadowLightPixel(7, previous), 0)));
}

bool worldPointShadowScheduled(sampler2D data, int slot, int frame, bool previous) {
    uvec2 mask = worldPointShadowMask(data, frame, previous);
    return (mask[slot / 32] & (1u << uint(slot % 32))) != 0u;
}

int worldShadowMaskCount(uint value) {
    value -= (value >> 1u) & 0x55555555u;
    value = (value & 0x33333333u) + ((value >> 2u) & 0x33333333u);
    value = (value + (value >> 4u)) & 0x0f0f0f0fu;
    return int((value * 0x01010101u) >> 24u);
}

// Coarse change bins are built once. Only the light's reach is inspected here;
// unchanged lamps retain their maps instead of waiting for a CPU state scan.
bool worldPointGeometryChanged(sampler2D data, WorldPointLight light) {
    ivec3 farOrigin = worldReadOrigin(data, false);
    ivec3 coverageOrigin = worldCoverageOrigin(farOrigin);
    vec3 position = vec3(light.position.block - coverageOrigin) + light.position.fraction;
    float reach = light.radius + 1.0;
    ivec3 low = max(ivec3(floor((position - reach) / 8.0)), ivec3(0));
    ivec3 high = min(ivec3(floor((position + reach) / 8.0)), worldCoverageShape() - 1);
    for (int z = 0; z < 7; z++) {
        if (low.z + z > high.z) break;
        for (int y = 0; y < 7; y++) {
            if (low.y + y > high.y) break;
            for (int x = 0; x < 7; x++) {
                if (low.x + x > high.x) break;
                ivec3 cell = low + ivec3(x, y, z);
                vec3 nearest = clamp(position, vec3(cell * 8), vec3(cell * 8 + 8));
                if (dot(nearest - position, nearest - position) > reach * reach) continue;
                ivec2 pixel = worldRegion(WORLD_REGION_FAR_COVERAGE).xy
                    + worldVoxelAddress(cell, worldCoverageShape(), 0, 0);
                if (texelFetch(data, pixel, 0).y > 0.5) return true;
            }
        }
    }
    return false;
}

vec3 worldPointFaceDirection(int face, vec2 uv) {
    vec2 p = uv * 2.0 - 1.0;
    if (face == 0) return normalize(vec3(1.0, -p.y, -p.x));
    if (face == 1) return normalize(vec3(-1.0, -p.y, p.x));
    if (face == 2) return normalize(vec3(p.x, 1.0, p.y));
    if (face == 3) return normalize(vec3(p.x, -1.0, -p.y));
    if (face == 4) return normalize(vec3(p.x, -p.y, 1.0));
    return normalize(vec3(-p.x, -p.y, -1.0));
}

vec3 worldPointFaceClip(int face, vec3 ray) {
    if (face == 0) return vec3(-ray.z, -ray.y, ray.x);
    if (face == 1) return vec3(ray.z, -ray.y, -ray.x);
    if (face == 2) return vec3(ray.x, ray.z, ray.y);
    if (face == 3) return vec3(ray.x, -ray.z, -ray.y);
    if (face == 4) return vec3(ray.x, -ray.y, ray.z);
    return vec3(-ray.x, -ray.y, -ray.z);
}

// A flat plane coefficient also carries the target tile in its low mantissa
// bits. The truncation is below the receiver bias; exponent/sign stay intact.
// Near-zero planes cannot occlude a ray at a positive distance and are skipped.
float worldShadowPlanePayload(float plane, int tile) {
    return uintBitsToFloat((floatBitsToUint(plane) & ~511u) | uint(tile));
}

float worldShadowPlaneDistance(float payload) {
    return uintBitsToFloat(floatBitsToUint(payload) & ~511u);
}

int worldShadowPlaneTile(float payload) {
    return int(floatBitsToUint(payload) & 511u);
}

// Four comparisons interpolate visibility, with each tap evaluated against the
// receiver plane. Cardinal hit planes prevent false strips at room corners.
float worldPointShadowVisibility(sampler2D data, int slot, vec3 ray, float radius, vec3 normal) {
    if (!worldShadowLightMapped(data, slot, false)) return 1.0;
    vec3 absolute = abs(ray);
    int axis = absolute.x >= absolute.y && absolute.x >= absolute.z ? 0 : absolute.y >= absolute.z ? 1 : 2;
    int face = axis * 2 + int(ray[axis] < 0.0);
    vec3 projected = worldPointFaceClip(face, ray);
    vec2 uv = projected.xy / max(projected.z, 0.00001) * 0.5 + 0.5;
    float inner = float(WORLD_POINT_SHADOW_SIDE - 2);
    vec2 pixel = uv * inner - 0.5;
    vec2 fraction = fract(pixel);
    ivec2 tile = ivec2((slot * 6 + face) % 24, (slot * 6 + face) / 24);
    ivec2 base = worldRegion(WORLD_REGION_POINT_SHADOWS).xy + tile * WORLD_POINT_SHADOW_SIDE;
    float distance = length(ray);
    float cosine = abs(dot(normal, ray)) / max(distance, 0.0001);
    float footprint = 2.0 * projected.z / inner;
    float bias = 0.012 + min(footprint * 0.6 / max(cosine, 0.35), 0.12);
    float visibility = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            ivec2 texel = clamp(ivec2(floor(pixel)) + ivec2(x, y), ivec2(0), ivec2(int(inner) - 1));
            vec4 hit = texelFetch(data, base + ivec2(1) + texel, 0);
            vec3 sampleRay = worldPointFaceDirection(face, (vec2(texel) + 0.5) / inner);
            float planeCosine = dot(sampleRay, normal);
            float receiver = abs(planeCosine) > 0.0001 ? dot(ray, normal) / planeCosine : distance;
            float depth = (max(min(receiver, distance), 0.0) - bias) / radius;
            float visible = step(depth, hit.r);
            if (hit.b < 0.9 && hit.b > 0.1) {
                vec3 hitNormal = hit.b < 0.375 ? vec3(1, 0, 0) : hit.b < 0.625 ? vec3(0, 1, 0) : vec3(0, 0, 1);
                float receiverPlane = dot(ray, hitNormal) / radius;
                float planeBias = 0.012 / radius + abs(hit.a) * 0.001;
                visible = receiverPlane * hit.a <= 0.0 ? 1.0 : step(abs(receiverPlane) - planeBias, abs(hit.a));
            }
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x) * (y == 0 ? 1.0 - fraction.y : fraction.y);
            visibility += visible * weight;
        }
    }
    return visibility;
}
#endif
