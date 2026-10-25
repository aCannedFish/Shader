#ifndef SIMPLE_WORLD_MODEL_QUERY_GLSL
#define SIMPLE_WORLD_MODEL_QUERY_GLSL
#include "/lib/world/model_surface.glsl"
#include "/lib/world/attributes.glsl"
#include "/lib/world/types.glsl"
#include "/lib/world/surface_material.glsl"
#ifdef WORLD_FULL_RENDERER
#include "/lib/foliage_wind.glsl"
#endif

struct WorldSurfaceHit {
    int status;
    float distance;
    vec3 normal;
    int quad;
    vec3 materialPoint;
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

// Deformed quads need the same two triangles as the native mesh. Barycentric
// coordinates recover the unbent material position for the alpha/colour lookup.
float worldIntersectWindTriangle(vec3 a, vec3 b, vec3 c, vec3 origin, vec3 direction,
    float minimum, float maximum, out vec3 barycentric, out vec3 normal) {
    vec3 first = b - a;
    vec3 second = c - a;
    vec3 crossRay = cross(direction, second);
    float determinant = dot(first, crossRay);
    barycentric = vec3(0.0);
    normal = normalize(cross(first, second));
    if (abs(determinant) < 1e-10) return maximum;
    vec3 point = origin - a;
    float u = dot(point, crossRay) / determinant;
    vec3 perpendicular = cross(point, first);
    float v = dot(direction, perpendicular) / determinant;
    if (min(u, v) < -0.00001 || u + v > 1.00001) return maximum;
    float distance = dot(second, perpendicular) / determinant;
    if (distance < minimum || distance >= maximum) return maximum;
    barycentric = vec3(1.0 - u - v, u, v);
    return distance;
}

float worldIntersectVisibleFace(WorldModelFace face, WorldAttributes attributes,
    float legacy, vec3 origin, vec3 direction, float minimum, float maximum,
    out vec3 normal, out vec3 materialPoint) {
    float distance = worldIntersectModelFace(face, origin, direction, minimum, maximum, normal);
    materialPoint = origin + direction * distance + attributes.offset.value;
#ifdef WORLD_FULL_RENDERER
    if (!hasFoliageWind(legacy)) return distance;
    vec3 a = face.a;
    vec3 b = face.b;
    vec3 c = face.c;
    vec3 d = a + c - b;
    vec3 base = vec3(attributes.owner.block) + attributes.offset.value;
    vec3 root = foliageRoot(vec3(attributes.owner.block) + vec3(0.5), legacy);
    vec3 bentA = a + foliageWindOffset(base + a, root, legacy);
    vec3 bentB = b + foliageWindOffset(base + b, root, legacy);
    vec3 bentC = c + foliageWindOffset(base + c, root, legacy);
    vec3 bentD = d + foliageWindOffset(base + d, root, legacy);
    vec3 barycentric;
    float first = worldIntersectWindTriangle(bentA, bentB, bentC, origin, direction,
        minimum, maximum, barycentric, normal);
    materialPoint = a * barycentric.x + b * barycentric.y + c * barycentric.z + attributes.offset.value;
    vec3 secondNormal;
    float second = worldIntersectWindTriangle(bentA, bentC, bentD, origin, direction,
        minimum, first, barycentric, secondNormal);
    if (second < first) {
        normal = secondNormal;
        materialPoint = a * barycentric.x + c * barycentric.y + d * barycentric.z + attributes.offset.value;
        return second;
    }
    return first;
#else
    return distance;
#endif
}

// An unresolved alternative in front of a confirmed face blocks acceptance.
// Unknown geometry cannot silently become a hole, a hidden wall or the sky.
WorldSurfaceHit worldIntersectModelFacing(sampler2D data, sampler2D staticData, sampler2D atlas,
    int material, WorldAttributes attributes, vec3 origin, vec3 direction,
    float minimum, float maximum, bool alphaClip, float alphaThreshold, bool frontOnly) {
    WorldSurfaceHit nearest = WorldSurfaceHit(WORLD_EXHAUSTED, maximum, vec3(0.0), -1, vec3(0.0));
    if (!attributes.offset.valid) {
        nearest.status = WORLD_UNCERTAIN;
        return nearest;
    }
    origin -= attributes.offset.value;
    WorldDefinition definition = worldReadDefinition(data, material);
    if ((definition.flags & 8) != 0) {
        nearest.status = WORLD_UNCERTAIN;
        return nearest;
    }
    bool geometryFixed = (definition.flags & 16) == 0;
    ivec2 list = worldSurfaceList(staticData, material);
    float uncertain = maximum;
    for (int entry = 0; entry < 512; entry++) {
        if (entry >= list.y) break;
        ivec2 reference = worldSurfaceReference(staticData, list.x + entry);
        bool enabled = worldModelFaceEnabled(reference, attributes);
        if (!enabled && attributes.modelValid) continue;
        int id = reference.x >> 8;
        WorldModelFace face = worldModelFace(staticData, id);
        vec3 normal;
        vec3 materialPoint;
        float distance = worldIntersectVisibleFace(face, attributes, float(definition.legacy),
            origin, direction, minimum, maximum, normal, materialPoint);
        if (distance >= maximum) continue;
        if (frontOnly && dot(normal, direction) >= -1e-8) continue;
        // A cutout hole continues to the next face, including geometry behind
        // this leaf. Missing UVs stop the query as uncertain, never as sky.
        if (alphaClip && definition.alphaType == 1) {
            WorldSurfaceMaterial surface = worldSampleModelMaterial(data, staticData, atlas,
                material, id, materialPoint, attributes);
            if (!surface.coverageValid) {
                uncertain = min(uncertain, distance);
                continue;
            }
            if (surface.alpha < alphaThreshold) continue;
        }
        if (!enabled && !geometryFixed) {
            uncertain = min(uncertain, distance);
        } else if (distance < nearest.distance) {
            nearest = WorldSurfaceHit(WORLD_HIT, distance, normal, id, materialPoint);
        }
    }
    if (uncertain < nearest.distance - 0.0001) nearest.status = WORLD_UNCERTAIN;
    return nearest;
}

// Shape/debug callers may intentionally inspect a model from its inside. Real
// reflection visibility follows native front-face culling via the facing API.
WorldSurfaceHit worldIntersectModel(sampler2D data, sampler2D staticData, sampler2D atlas,
    int material, WorldAttributes attributes, vec3 origin, vec3 direction,
    float minimum, float maximum, bool alphaClip, float alphaThreshold) {
    return worldIntersectModelFacing(data, staticData, atlas, material, attributes,
        origin, direction, minimum, maximum, alphaClip, alphaThreshold, false);
}
#endif
