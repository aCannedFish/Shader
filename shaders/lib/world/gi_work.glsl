#include "/lib/world/solar_parameters.glsl"
#ifndef SIMPLE_WORLD_GI_WORK_GLSL
#define SIMPLE_WORLD_GI_WORK_GLSL
#include "/lib/world/gi.glsl"
#include "/lib/world/point_shadow.glsl"
#include "/lib/world/glass_cache.glsl"
#include "/lib/world/glass_query.glsl"

struct WorldGiVoxel {
    int state;
    int material;
    vec3 albedo;
    vec3 absorption;
    float skylight;
};

WorldGiVoxel worldGiLiveVoxel(sampler2D data, WorldPosition owner) {
    WorldSample sample = worldRead(data, owner);
    WorldDefinition definition = worldReadDefinition(data, sample.material);
    int state = (definition.flags & 128) != 0 ? WORLD_WATER : sample.state;
    return WorldGiVoxel(state, sample.material, sample.albedo, definition.absorption, sample.light.y);
}

WorldGiVoxel worldGiVoxel(sampler2D data, ivec3 cell, WorldGiState work) {
    if (!worldCellValid(cell, ivec3(WORLD_GI_SIZE))) return WorldGiVoxel(WORLD_UNKNOWN, 0, vec3(0.0), vec3(0.0), 0.0);
    if (work.bounce == 0 && work.iteration == 0) {
        return worldGiLiveVoxel(data, WorldPosition(work.origin + cell, vec3(0.5)));
    }
    vec4 material = worldGiCoefficient(data, WORLD_REGION_GI_SCENE, cell, 0);
    vec4 medium = worldGiCoefficient(data, WORLD_REGION_GI_MEDIUM, cell, 0);
    int metadata = int(round(medium.a));
    int alias = int(round(material.a)) + (metadata & 15) * 2048;
    return WorldGiVoxel((metadata >> 4) & 7, alias, material.rgb, medium.rgb, float(metadata >> 7) / 15.0);
}

bool worldGiPassable(WorldGiVoxel voxel) {
    return voxel.state == WORLD_AIR || voxel.state == WORLD_WATER || voxel.state == WORLD_TRANSMISSION;
}

vec3 worldGiSegmentTransfer(sampler2D data, sampler2D resource, ivec3 from, ivec3 to, WorldGiState work) {
    vec3 direction = vec3(to - from);
    vec3 transfer = vec3(1.0);
    for (int endpoint = 0; endpoint < 2; endpoint++) {
        ivec3 cell = endpoint == 0 ? from : to;
        WorldGiVoxel voxel = worldGiVoxel(data, cell, work);
        if (voxel.state != WORLD_TRANSMISSION) continue;
        if (max(voxel.absorption.r, max(voxel.absorption.g, voxel.absorption.b)) <= 0.0) continue;
        WorldPosition owner = WorldPosition(work.origin + cell, vec3(0.5));
        WorldAttributes attributes = WorldAttributes(owner, vec3(1.0),
            worldDecodeModelOffset(resource, voxel.material, ivec3(0)), 0u, true, true);
        vec3 origin = vec3(from - cell) + 0.5;
        float distance = worldGlassPathLength(data, voxel.material, attributes, origin, direction, 0.0, 1.0);
        if (distance < 0.0) return vec3(0.0);
        transfer *= exp(-voxel.absorption * distance);
    }
    return transfer;
}

// Prototype and complete-renderer entry points use the same shadow geometry.
// An unknown/out-of-range solar projection supplies no unverified direct energy.
vec3 worldGiSolarVisibility(sampler2D depth, WorldPosition position, vec3 camera,
    mat4 view, mat4 projection) {
    vec4 clip = projection * view * vec4(worldCameraRelative(position, camera), 1.0);
    vec3 p = clip.xyz / clip.w;
    p.xy /= (1.0 - SHADOW_MAP_BIAS) + length(p.xy) * SHADOW_MAP_BIAS;
#ifndef WORLD_FULL_RENDERER
    p.z *= 0.2;
#endif
    vec3 uv = p * 0.5 + 0.5;
    if (any(lessThan(uv, vec3(0.0))) || any(greaterThan(uv, vec3(1.0)))) return vec3(0.0);
    vec2 atlas = (vec2(WORLD_CAPTURE_SOLAR.xy) + uv.xy * vec2(WORLD_CAPTURE_SOLAR.zw)) / float(WORLD_CAPTURE_SIDE);
    return vec3(step(uv.z - 0.0005, textureLod(depth, atlas, 0.0).r));
}

vec3 worldGiDirectLight(sampler2D data, sampler2D sunDepth, WorldPosition position, vec3 normal,
    float skylight, vec3 camera, mat4 shadowView, mat4 shadowProjection) {
    vec3 sunDirection = worldGiHeader(data, 13).xyz;
    vec3 sunColour = worldGiHeader(data, 14).rgb;
    vec3 result = sunColour * max(dot(normal, sunDirection), 0.0)
        * worldGiSolarVisibility(sunDepth, position, camera, shadowView, shadowProjection)
        * smoothstep(0.5, 0.95, skylight);
    for (int slot = 0; slot < WORLD_POINT_LIGHT_COUNT; slot++) {
        WorldPointLight light = worldReadPointLight(data, slot);
        if (!light.valid) continue;
        vec3 delta = vec3(light.position.block - position.block) + light.position.fraction - position.fraction;
        float squared = dot(delta, delta);
        if (squared >= light.radius * light.radius || squared < 0.00001) continue;
        float cutoff = 1.0 - squared / (light.radius * light.radius);
        float cosine = max(dot(normal, delta * inversesqrt(squared)), 0.0);
        if (cosine <= 0.0) continue;
        float visibility = worldPointShadowVisibility(data, slot, -delta, light.radius, normal);
        vec3 transfer = visibility > 0.0 ? worldPointGlassFilter(data, slot, position, normal) : vec3(0.0);
        result += light.emission * (2.0 * light.level / 15.0) * cutoff * cutoff / (1.0 + squared)
            * cosine * visibility * transfer;
    }
    return result;
}

vec4 worldGiNextStep(sampler2D data, sampler2D resource, sampler2D sunDepth,
    ivec3 cell, int band, WorldGiState work, vec3 camera, mat4 shadowView, mat4 shadowProjection) {
    WorldGiVoxel receiver = worldGiVoxel(data, cell, work);
    if (!worldGiPassable(receiver)) return vec4(0.0);
    vec4 result = vec4(0.0);
    for (int face = 0; face < 6; face++) {
        ivec3 axis = ivec3(0);
        axis[face / 2] = face % 2 == 0 ? 1 : -1;
        ivec3 neighbour = cell + axis;
        if (!worldCellValid(neighbour, ivec3(WORLD_GI_SIZE))) continue;
        WorldGiVoxel adjacent = worldGiVoxel(data, neighbour, work);
        vec3 direction = -vec3(axis);
        vec3 radiance;
        if (work.iteration == 0) {
            if (adjacent.state != WORLD_SURFACE) continue;
            if (work.bounce == 0) {
                WorldPosition position = WorldPosition(work.origin + cell, vec3(0.5) + vec3(axis) * 0.47);
                radiance = worldGiDirectLight(data, sunDepth, position, direction,
                    max(receiver.skylight, adjacent.skylight), camera, shadowView, shadowProjection);
            } else {
                radiance = worldGiIrradiance(data, WORLD_REGION_GI_PREVIOUS_BOUNCE, cell, vec3(axis));
            }
            radiance *= min(adjacent.albedo, vec3(0.85)) * GI_REFLECTANCE / 3.14159265;
        } else {
            if (!worldGiPassable(adjacent)) continue;
            float channel = max(dot(worldGiCoefficient(data, WORLD_REGION_GI_STEP, neighbour, band),
                vec4(0.282095, direction * 0.488603)), 0.0) * 0.5;
            if (receiver.state == WORLD_TRANSMISSION || adjacent.state == WORLD_TRANSMISSION) {
                channel *= worldGiSegmentTransfer(data, resource, neighbour, cell, work)[band];
            }
            result += worldGiLobe(direction) * channel;
            continue;
        }
        result += worldGiLobe(direction) * radiance[band];
    }
    return result;
}
#endif
