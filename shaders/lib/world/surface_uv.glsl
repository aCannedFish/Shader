#ifndef SIMPLE_WORLD_SURFACE_UV_GLSL
#define SIMPLE_WORLD_SURFACE_UV_GLSL
#include "/lib/world/lookup.glsl"
#include "/lib/world/uv.glsl"
#include "/lib/world/model_surface.glsl"

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

WorldUv worldReadModelUv(sampler2D data, sampler2D resource, int material, vec3 point, vec3 normal) {
    ivec2 list = worldSurfaceList(resource, material);
    for (int entry = 0; entry < 512; entry++) {
        if (entry >= list.y) break;
        int id = worldSurfaceId(resource, list.x + entry);
        WorldModelFace face = worldModelFace(resource, id);
        if (!worldPointOnModelFace(face, point, normal)) continue;
        WorldUv mapping = worldReadFaceMapping(data, id);
        if (mapping.valid) return mapping;
        // A texture observed on another face can shade a hidden face. Missing
        // observations remain invalid, rather than sampling unrelated texels.
        WorldUv textureMapping = worldReadFaceMapping(data, WORLD_TEXTURE_UV_START + face.texture);
        if (textureMapping.valid) {
            mapping = WorldUv(face.u * textureMapping.u.x, face.v * textureMapping.v.y, true, face.tint >= 0);
            mapping.u.z += textureMapping.u.z;
            mapping.v.z += textureMapping.v.z;
            return mapping;
        }
    }
    return WorldUv(vec3(0.0), vec3(0.0), false, false);
}
#endif
