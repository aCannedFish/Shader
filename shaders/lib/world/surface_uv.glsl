#ifndef SIMPLE_WORLD_SURFACE_UV_GLSL
#define SIMPLE_WORLD_SURFACE_UV_GLSL
#include "/lib/world/lookup.glsl"
#include "/lib/world/uv.glsl"
#include "/lib/world/model_surface.glsl"
#include "/lib/world/attributes.glsl"

WorldUv worldReadUvWords(sampler2D data, ivec2 first, ivec2 step) {
    return worldDecodeUv(texelFetch(data, first, 0), texelFetch(data, first + step, 0),
        texelFetch(data, first + step * 2, 0));
}

// The caller must identify the owning face. This mapping describes the current
// observed face, not an arbitrary model part or a proof of complete coverage.
WorldUv worldReadNearUv(sampler2D data, WorldPosition owner, int face) {
    ivec3 origin = worldReadOrigin(data, true);
    ivec3 cell = worldFloorDivide(worldGridCell(owner, origin, 2), 2);
    if (face < 0 || face >= 6 || !worldCellValid(cell, WORLD_NEAR_SHAPE / 2)) {
        return WorldUv(vec3(0.0), vec3(0.0), false, false);
    }
    ivec2 raw = worldNearFaceAddress(cell, face);
    ivec2 first = worldRegion(WORLD_REGION_NEAR_FACES).xy + ivec2(raw.x * 3, raw.y);
    return worldReadUvWords(data, first, ivec2(1, 0));
}

WorldUv worldReadFaceMapping(sampler2D data, int record) {
    ivec4 rectangle = worldRegion(WORLD_REGION_MATERIAL_FACES);
    vec4 words[3];
    for (int word = 0; word < 3; word++) {
        int index = record * 3 + word;
        words[word] = texelFetch(data, rectangle.xy + ivec2(index % rectangle.z, index / rectangle.z), 0);
    }
    return worldDecodeUv(words[0], words[1], words[2]);
}

// Canonical mappings are independent of a block's random displacement. The
// query applies it once when converting back to actual surface coordinates.
WorldUv worldReadModelFaceUv(sampler2D data, sampler2D staticData, int id, WorldAttributes attributes) {
    WorldModelFace face = worldModelFace(staticData, id);
    WorldUv mapping = worldReadFaceMapping(data, id);
    if (!mapping.valid) {
        WorldUv textureMapping = worldReadFaceMapping(data, WORLD_TEXTURE_UV_START + face.texture);
        if (textureMapping.valid) {
            mapping = WorldUv(face.u * textureMapping.u.x, face.v * textureMapping.v.y, true, face.tint >= 0);
            mapping.u.z += textureMapping.u.z;
            mapping.v.z += textureMapping.v.z;
        }
    }
    if (mapping.valid) {
        int axis = face.face / 2;
        vec2 displacement = worldSurfaceProjection(attributes.offset.value, axis);
        mapping.u.z -= dot(mapping.u.xy, displacement);
        mapping.v.z -= dot(mapping.v.xy, displacement);
        mapping.tinted = face.tint >= 0;
    }
    return mapping;
}

WorldUv worldReadModelUv(sampler2D data, sampler2D staticData, int material,
    vec3 point, vec3 normal, WorldAttributes attributes) {
    if (!attributes.offset.valid) return WorldUv(vec3(0.0), vec3(0.0), false, false);
    ivec2 list = worldSurfaceList(staticData, material);
    for (int entry = 0; entry < 512; entry++) {
        if (entry >= list.y) break;
        ivec2 reference = worldSurfaceReference(staticData, list.x + entry);
        if (!worldModelFaceEnabled(reference, attributes)) continue;
        int id = reference.x >> 8;
        WorldModelFace face = worldModelFace(staticData, id);
        if (!worldPointOnModelFace(face, point - attributes.offset.value, normal)) continue;
        WorldUv mapping = worldReadModelFaceUv(data, staticData, id, attributes);
        if (mapping.valid) return mapping;
    }
    return WorldUv(vec3(0.0), vec3(0.0), false, false);
}
#endif
