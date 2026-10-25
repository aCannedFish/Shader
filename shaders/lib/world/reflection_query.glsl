/* World-space nearest-hit queries for reflection consumers. DDA visits only
 * known cells; cutout holes continue to the next real face, glass integrates
 * volume absorption, and unknown data has its own termination status.
 */
#ifndef SIMPLE_WORLD_REFLECTION_QUERY_GLSL
#define SIMPLE_WORLD_REFLECTION_QUERY_GLSL
#include "/lib/world/model_query.glsl"
#include "/lib/world/glass_query.glsl"
#include "/lib/world/lighting_backend.glsl"
#include "/lib/lighting.glsl"
#include "/lib/space.glsl"
#include "/lib/shadow_filter.glsl"

uniform sampler2D worldTextureAtlas;

#ifndef WORLD_REFLECTION_STEPS
#define WORLD_REFLECTION_STEPS 64
#endif

WorldHit worldEmptyReflection(int status, float distance) {
    return WorldHit(status, distance, vec3(0.0), vec3(0.0), vec2(0.0), 0,
        0.0, vec3(1.0), vec3(0.0), 0.0);
}

vec3 worldReflectionSolar(WorldPosition position, vec3 normal) {
#if SIMPLE_DIMENSION != 0
    return vec3(1.0);
#else
    vec3 relative = worldCameraRelative(position, cameraPosition);
    vec4 clip = shadowProjection * shadowModelView * vec4(relative + normal * 0.015, 1.0);
    vec3 coordinate = distortShadow(clip.xyz / clip.w) * 0.5 + 0.5;
    if (any(lessThan(coordinate, vec3(0.0))) || any(greaterThan(coordinate, vec3(1.0)))) {
        return vec3(0.0);
    }
    float visible = filteredShadowVisibility(shadowtex0, coordinate.xy, coordinate.z - 0.00003);
    return vec3(visible);
#endif
}

// Hit surfaces use the same native field, hue, point visibility and published
// GI as directly visible surfaces. A hidden face is shaded from its own colour.
vec3 worldReflectionRadiance(WorldPosition position, vec3 normal, vec2 light,
    WorldSurfaceMaterial surface, WorldDefinition definition) {
    vec3 relative = worldCameraRelative(position, cameraPosition);
    vec3 view = (gbufferModelView * vec4(relative, 1.0)).xyz;
    vec3 normalView = normalize(mat3(gbufferModelView) * normal);
    vec2 lm = vec2(0.03125) + light * 0.9375;
    vec3 block = companionBlockLight(view, normalView, lm, blockLightRadiance(lm));
    vec3 indirect = worldIndirectLight(colortex6, position, normal);
    vec3 ambient = vec3(MIN_AMBIENT_LIGHT) * AMBIENT_STRENGTH;
#if SIMPLE_DIMENSION == 0
    // Composite stages do not bind the native lightmap. Use the recorded
    // native sky level and common atmospheric inputs instead of sampling unit 0.
    float sky = smoothstep(0.03, 0.95, light.y);
    vec3 fill = toLinearSpace(skyColor) * mix(0.08, 0.45, getDayFactor());
    fill *= mix(vec3(1.0), vec3(0.38, 0.58, 1.0), getNightFactor());
    fill *= mix(1.0, 0.75, weatherRainAmount());
    fill += vec3(0.38, 0.58, 1.0) * NIGHT_AMBIENT_STRENGTH * getNightFactor();
    ambient += fill * sky * AMBIENT_STRENGTH;
    vec3 direct = getSunLightColor() * max(dot(normalView, normalize(sunPosition)), 0.0)
        + getMoonLightColor() * max(dot(normalView, normalize(moonPosition)), 0.0);
    direct *= worldReflectionSolar(position, normal) * smoothstep(0.60, 0.96, light.y);
#else
    ambient += dimensionAmbient(normal) * AMBIENT_STRENGTH;
    vec3 direct = vec3(0.0);
#endif
    vec3 radiance = surface.albedo * (ambient + block + indirect + direct);
    if (definition.emissionLevel > 0) {
        float emission = definition.legacy == 101 ? 1.6 : 1.0;
        radiance = max(radiance, surface.albedo * emission);
    }
    return radiance;
}

WorldHit worldTraceReflection(WorldPosition origin, vec3 direction, float minimum,
    float maximum, int budget) {
    WorldHit result = worldEmptyReflection(WORLD_INVALID, 0.0);
    float magnitude = length(direction);
    if (magnitude < 0.00001 || any(isnan(direction)) || any(isinf(direction))) return result;
    direction /= magnitude;
    vec3 start = origin.fraction;
    vec3 advance = start + direction * minimum;
    ivec3 cell = ivec3(floor(advance));
    ivec3 stepCell = ivec3(sign(direction));
    vec3 inverse = 1.0 / max(abs(direction), vec3(1e-20));
    vec3 boundary = vec3(cell) + step(vec3(0.0), direction);
    vec3 next = (boundary - start) / mix(vec3(1e-20), direction,
        greaterThan(abs(direction), vec3(1e-20)));
    for (int axis = 0; axis < 3; axis++) {
        if (stepCell[axis] == 0) next[axis] = 1e20;
    }
    vec3 transmission = vec3(1.0);
    float distance = minimum;
    ivec3 farOrigin = worldReadOrigin(colortex6, false);
    bool uncertainPath = false;
    for (int iteration = 0; iteration < 128; iteration++) {
        if (iteration >= budget) break;
        WorldPosition owner = WorldPosition(origin.block + cell, vec3(0.5));
        ivec3 index = owner.block - farOrigin;
        if (!worldCellValid(index, WORLD_FAR_SHAPE)) {
            result.status = WORLD_OUTSIDE;
            result.distance = distance;
            result.transmission = transmission;
            return result;
        }
        ivec3 brick = index / 4;
        ivec2 coverage = worldRegion(WORLD_REGION_RAY_COVERAGE).xy
            + worldVoxelAddress(brick, WORLD_FAR_SHAPE / 4, 0, 0);
        if (texelFetch(colortex6, coverage, 0).x > 0.5) {
            vec3 low = vec3(farOrigin + brick * 4 - origin.block);
            vec3 edge = low + step(vec3(0.0), direction) * 4.0;
            vec3 exit = (edge - start) / mix(vec3(1e-20), direction,
                greaterThan(abs(direction), vec3(1e-20)));
            for (int axis = 0; axis < 3; axis++) {
                if (stepCell[axis] == 0) exit[axis] = 1e20;
            }
            float crossing = min(exit.x, min(exit.y, exit.z));
            if (crossing >= maximum) {
                result.status = WORLD_EXHAUSTED;
                result.distance = maximum;
                result.transmission = transmission;
                return result;
            }
            cell = ivec3(floor(start + direction * (crossing + 0.00001)));
            boundary = vec3(cell) + step(vec3(0.0), direction);
            next = (boundary - start) / mix(vec3(1e-20), direction,
                greaterThan(abs(direction), vec3(1e-20)));
            for (int axis = 0; axis < 3; axis++) {
                if (stepCell[axis] == 0) next[axis] = 1e20;
            }
            distance = crossing;
            continue;
        }
        WorldSample observed = worldReadCell(colortex6, owner, false);
        if (observed.state == WORLD_UNKNOWN) {
            // Keep searching for a known surface as a fallback candidate.
            // The path remains uncertain; it is never reclassified as air or sky.
            uncertainPath = true;
        }
        float end = min(maximum, min(next.x, min(next.y, next.z)));
        if (observed.state == WORLD_SURFACE || observed.state == WORLD_TRANSMISSION) {
            WorldDefinition definition = worldReadDefinition(colortex6, observed.material);
            WorldAttributes attributes = worldReadAttributes(colortex6, noisetex, owner, observed.material);
            vec3 local = start - vec3(cell);
            if (observed.state == WORLD_TRANSMISSION) {
                bool valid;
                vec3 transfer = worldQueryGlassTransmission(colortex6, observed.material,
                    attributes, local, direction, distance, end, valid);
                if (!valid) {
                    result.status = WORLD_UNCERTAIN;
                    result.distance = distance;
                    result.transmission = transmission;
                    return result;
                }
                transmission *= transfer;
            } else {
                WorldSurfaceHit hit = worldIntersectModelFacing(colortex6, noisetex, worldTextureAtlas,
                    observed.material, attributes, local, direction, distance, end + 0.00002, true, 0.1, true);
                if (hit.status == WORLD_UNCERTAIN) {
                    uncertainPath = true;
                }
                if (hit.status == WORLD_HIT) {
                    vec3 point = local + direction * hit.distance;
                    WorldModelFace face = worldModelFace(noisetex, hit.quad);
                    vec3 materialNormal = normalize(cross(face.b - face.a, face.c - face.a));
                    WorldSurfaceMaterial surface = worldSampleModelLayers(colortex6, noisetex,
                        worldTextureAtlas, observed.material, hit.materialPoint, materialNormal, attributes);
                    if (!surface.valid || !surface.coverageValid) {
                        result.status = WORLD_UNCERTAIN;
                        result.distance = hit.distance;
                        result.transmission = transmission;
                        return result;
                    }
                    vec3 normal = dot(hit.normal, direction) > 0.0 ? -hit.normal : hit.normal;
                    WorldPosition position = WorldPosition(owner.block + ivec3(floor(point)), fract(point));
                    result = worldEmptyReflection(uncertainPath ? WORLD_UNCERTAIN : WORLD_HIT, hit.distance);
                    result.position = worldCameraRelative(position, cameraPosition);
                    result.normal = normal;
                    result.material = observed.material;
                    WorldUv mapping = worldReadModelFaceUv(colortex6, noisetex, hit.quad, attributes);
                    result.uv = mapping.valid
                        ? worldSurfaceUv(mapping, worldSurfaceProjection(point, worldSurfaceAxis(hit.normal))) : vec2(0.0);
                    result.coverage = surface.alpha;
                    result.transmission = transmission;
                    result.radiance = worldReflectionRadiance(position, normal, observed.light, surface, definition)
                        * transmission;
                    result.confidence = uncertainPath ? 0.5 : 1.0;
                    return result;
                }
            }
        }
        if (end >= maximum) {
            result.status = WORLD_EXHAUSTED;
            result.distance = maximum;
            result.transmission = transmission;
            return result;
        }
        // Advance all tied axes together. Corner crossings must not revisit an
        // empty zero-length interval or accidentally skip the next actual cell.
        float crossing = min(next.x, min(next.y, next.z));
        bvec3 tied = lessThanEqual(next, vec3(crossing + 0.000001));
        cell += ivec3(tied) * stepCell;
        next += vec3(tied) * inverse;
        distance = crossing;
    }
    result.status = WORLD_EXHAUSTED;
    result.distance = distance;
    result.transmission = transmission;
    return result;
}
#endif
