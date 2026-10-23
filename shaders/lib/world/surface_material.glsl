#ifndef SIMPLE_WORLD_SURFACE_MATERIAL_GLSL
#define SIMPLE_WORLD_SURFACE_MATERIAL_GLSL
#include "/lib/world/surface_uv.glsl"

struct WorldSurfaceMaterial {
    vec3 albedo;
    vec3 emission;
    vec3 absorption;
    float alpha;
    int alphaType;
    bool valid;
    bool coverageValid;
};

// Sample the hit face, rather than the block's average observed colour. Tint
// applies only to tinted faces, so grass bases and overlays keep their colours.
WorldSurfaceMaterial worldSampleModelMaterial(sampler2D data, sampler2D resource, sampler2D atlas,
    int material, int quad, vec3 point, WorldAttributes attributes) {
    WorldDefinition definition = worldReadDefinition(data, material);
    WorldSurfaceMaterial result = WorldSurfaceMaterial(vec3(0.0),
        definition.emission * float(definition.emissionLevel), definition.absorption,
        0.0, definition.alphaType, false, false);
    WorldModelFace face = worldModelFace(resource, quad);
    WorldUv mapping = attributes.modelValid ? worldReadModelFaceUv(data, resource, quad, attributes)
        : worldReadNearUv(data, attributes.owner, face.face);
    // A UV-only ambiguity still has deterministic geometry. Its observed
    // per-block face is usable, while an unseen orientation remains unknown.
    if (!mapping.valid) return result;
    vec2 uv = worldSurfaceUv(mapping, worldSurfaceProjection(point, face.face / 2));
    vec4 texel = textureLod(atlas, uv, 0.0);
    vec3 colour = mapping.tinted ? attributes.tint : vec3(1.0);
    result.albedo = pow(max(texel.rgb * colour, vec3(0.0)), vec3(2.2));
    result.alpha = texel.a;
    result.coverageValid = true;
    result.valid = !mapping.tinted || attributes.tintValid;
    return result;
}

// Coincident model layers compose in resource order. Alpha clipping affects
// coverage; tint and base texture remain independent until this operation.
WorldSurfaceMaterial worldSampleModelLayers(sampler2D data, sampler2D resource, sampler2D atlas,
    int material, vec3 point, vec3 normal, WorldAttributes attributes) {
    WorldDefinition definition = worldReadDefinition(data, material);
    WorldSurfaceMaterial result = WorldSurfaceMaterial(vec3(0.0),
        definition.emission * float(definition.emissionLevel), definition.absorption,
        0.0, definition.alphaType, true, true);
    ivec2 list = worldSurfaceList(resource, material);
    bool observed = false;
    for (int entry = 0; entry < 512; entry++) {
        if (entry >= list.y) break;
        ivec2 reference = worldSurfaceReference(resource, list.x + entry);
        if (!worldModelFaceEnabled(reference, attributes) && attributes.modelValid) continue;
        int id = reference.x >> 8;
        WorldModelFace face = worldModelFace(resource, id);
        if (!worldPointOnModelFace(face, point - attributes.offset.value, normal)) continue;
        // If only UV selection is unresolved, a single observed mapping fully
        // describes that face. Repeating it for every candidate duplicates alpha.
        if (!attributes.modelValid && observed) continue;
        WorldSurfaceMaterial layer = worldSampleModelMaterial(data, resource, atlas,
            material, id, point, attributes);
        observed = true;
        if (!layer.coverageValid) {
            result.coverageValid = false;
            result.valid = false;
            continue;
        }
        if (layer.alpha <= 0.0) continue;
        if (layer.alpha >= 1.0) result.valid = layer.valid;
        else result.valid = result.valid && layer.valid;
        result.albedo = layer.albedo * layer.alpha + result.albedo * (1.0 - layer.alpha);
        result.alpha = layer.alpha + result.alpha * (1.0 - layer.alpha);
    }
    result.albedo /= max(result.alpha, 0.00001);
    result.coverageValid = observed && result.coverageValid;
    result.valid = observed && result.valid;
    return result;
}

// Glass absorption is per metre. Alpha is a surface coverage value and must
// not be multiplied again for every crossed face of the same volume.
vec3 worldGlassTransmission(WorldSurfaceMaterial material, float pathLength) {
    return exp(-max(material.absorption, vec3(0.0)) * max(pathLength, 0.0));
}
#endif
