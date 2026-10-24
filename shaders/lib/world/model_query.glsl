#ifndef SIMPLE_WORLD_MODEL_QUERY_GLSL
#define SIMPLE_WORLD_MODEL_QUERY_GLSL
#include "/lib/world/model_surface.glsl"
#include "/lib/world/attributes.glsl"
#include "/lib/world/types.glsl"
#include "/lib/world/surface_material.glsl"

struct WorldSurfaceHit {
    int status;
    float distance;
    vec3 normal;
    int quad;
};

// Model quads are planar parallelograms, including rescaled rotated elements.
// Solve their local basis instead of intersecting the union of candidate boxes.
float worldIntersectModelFace(WorldModelFace face, vec3 origin, vec3 direction,
    float minimum, float maximum, out vec3 normal) {
    vec3 first = face.b - face.a;
    vec3 second = face.c - face.b;
    normal = normalize(cross(first, second));
    float denominator = dot(normal, direction);
    if (abs(denominator) < 1e-8) return maximum;
    float distance = dot(face.a - origin, normal) / denominator;
    if (distance < minimum || distance >= maximum) return maximum;
    vec3 point = origin + direction * distance - face.a;
    float aa = dot(first, first);
    float ab = dot(first, second);
    float bb = dot(second, second);
    float determinant = aa * bb - ab * ab;
    if (determinant < 1e-12) return maximum;
    vec2 coordinate = vec2(bb * dot(point, first) - ab * dot(point, second),
        aa * dot(point, second) - ab * dot(point, first)) / determinant;
    if (any(lessThan(coordinate, vec2(-0.00002)))
        || any(greaterThan(coordinate, vec2(1.00002)))) return maximum;
    return distance;
}

// An unresolved alternative in front of a confirmed face blocks acceptance.
// Unknown geometry cannot silently become a hole, a hidden wall or the sky.
WorldSurfaceHit worldIntersectModel(sampler2D data, sampler2D resource, sampler2D atlas,
    int material, WorldAttributes attributes, vec3 origin, vec3 direction,
    float minimum, float maximum, bool alphaClip, float alphaThreshold) {
    WorldSurfaceHit nearest = WorldSurfaceHit(WORLD_EXHAUSTED, maximum, vec3(0.0), -1);
    if (!attributes.offset.valid) {
        nearest.status = WORLD_UNCERTAIN;
        return nearest;
    }
    vec3 displacedOrigin = origin;
    origin -= attributes.offset.value;
    WorldDefinition definition = worldReadDefinition(data, material);
    if ((definition.flags & 8) != 0) {
        nearest.status = WORLD_UNCERTAIN;
        return nearest;
    }
    bool geometryFixed = (definition.flags & 16) == 0;
    ivec2 list = worldSurfaceList(resource, material);
    float uncertain = maximum;
    for (int entry = 0; entry < 512; entry++) {
        if (entry >= list.y) break;
        ivec2 reference = worldSurfaceReference(resource, list.x + entry);
        bool enabled = worldModelFaceEnabled(reference, attributes);
        if (!enabled && attributes.modelValid) continue;
        int id = reference.x >> 8;
        WorldModelFace face = worldModelFace(resource, id);
        vec3 normal;
        float distance = worldIntersectModelFace(face, origin, direction, minimum, maximum, normal);
        if (distance >= maximum) continue;
        // A cutout hole continues to the next face, including geometry behind
        // this leaf. Missing UVs stop the query as uncertain, never as sky.
        if (alphaClip && definition.alphaType == 1) {
            WorldSurfaceMaterial surface = worldSampleModelMaterial(data, resource, atlas,
                material, id, displacedOrigin + direction * distance, attributes);
            if (!surface.coverageValid) {
                uncertain = min(uncertain, distance);
                continue;
            }
            if (surface.alpha < alphaThreshold) continue;
        }
        if (!enabled && !geometryFixed) {
            uncertain = min(uncertain, distance);
        } else if (distance < nearest.distance) {
            nearest = WorldSurfaceHit(WORLD_HIT, distance, normal, id);
        }
    }
    if (uncertain < nearest.distance - 0.0001) nearest.status = WORLD_UNCERTAIN;
    return nearest;
}
#endif
