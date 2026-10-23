#include "/lib/world/coordinates.glsl"
#include "/lib/world/capture_layout.glsl"
#include "/lib/world/uv.glsl"
#include "/lib/world/atlas_uv.glsl"
#ifdef WORLD_MODEL_UV
#include "/lib/world/model_surface.glsl"
#include "/lib/world/model_choices.glsl"
uniform sampler2D noisetex;
#endif
layout(triangles) in;
layout(triangle_strip, max_vertices=31) out;
in WorldVertex {
    vec3 centre;
    vec3 position;
    vec2 uv;
    vec3 colour;
    float material;
    float light;
} vertex[];
uniform vec3 cameraPosition;
uniform vec4 spriteBounds;
uniform ivec2 atlasSize;
uniform sampler2D gtexture;
out vec2 sampleUv;
out vec3 sampleColour;
flat out int captureRoute;
flat out vec4 captureMetadata;
flat out vec4 captureU;
flat out vec4 captureV;
flat out vec4 captureGroups;

// Two 2x2 quads cover eight half-block cells. Face priority is independent of
// yaw, so overlapping submitted triangles cannot flicker with draw order.
void worldEmitRecord(ivec2 pixel, ivec2 size, int face, int flags, bool priorityTint, ivec3 offsetCode) {
    for (int corner = 0; corner < 4; corner++) {
        ivec2 offset = ivec2(corner % 2, corner / 2) * size;
        vec2 ndc = vec2(pixel + offset) / float(WORLD_CAPTURE_SIDE) * 2.0 - 1.0;
        gl_Position = vec4(ndc, -0.98 + float(face) * 0.0001 - (priorityTint ? 0.001 : 0.0), 1.0);
        captureRoute = 1;
        captureU = captureV = vec4(0.0);
        captureU = vec4(offsetCode, flags);
        sampleUv = (vertex[0].uv + vertex[1].uv + vertex[2].uv) / 3.0;
        sampleColour = (vertex[0].colour + vertex[1].colour + vertex[2].colour) / 3.0;
        captureMetadata = vec4(max(vertex[0].material, 0.0), vertex[0].light,
            float(face), 1.0);
        captureGroups = vec4(0.0);
        EmitVertex();
    }
    EndPrimitive();
}

// Record the affine mapping before alpha testing. A hole in a leaf must still
// carry the mapping needed to continue a later alpha-aware ray query.
void worldEmitUv(ivec2 pixel, WorldUv mapping) {
    for (int corner = 0; corner < 4; corner++) {
        ivec2 offset = ivec2(corner % 2, corner / 2);
        gl_Position = vec4(vec2(pixel + offset) / float(WORLD_CAPTURE_SIDE) * 2.0 - 1.0,
            -0.99, 1.0);
        captureRoute = 2;
        sampleUv = vec2(0.0);
        sampleColour = vec3(1.0);
        captureMetadata = vec4(0.0);
        captureU = vec4(mapping.u, 517.0);
        captureV = vec4(mapping.v, mapping.tinted ? 518.0 : 517.0);
        captureGroups = vec4(0.0);
        EmitVertex();
    }
    EndPrimitive();
}

#ifdef WORLD_MODEL_UV
// Only one triangle of each submitted quad contributes. Independent additive
// moments reject conflicting choices instead of averaging model identities.
void worldEmitChoice(ivec3 cell, int material, int hint, int condition) {
    if (hint == 0 || gl_PrimitiveIDIn % 2 != 0) return;
    ivec4 range = worldModelChoiceRange(noisetex, material);
    int index = hint >= 192 ? hint - 192 : hint >= 128 ? hint - 128 : hint / 16 - 1;
    if (index < 0 || index >= range.y) return;
    WorldChoiceGroup group = worldModelChoiceGroup(noisetex, range, index);
    vec4 contribution = hint >= 192 ? worldChoiceConstraintContribution(group, uint(condition))
        : hint >= 128 ? worldChoiceCoverage(group)
        : worldChoiceContribution(group, hint % 16);
    ivec2 pixel = WORLD_CAPTURE_CHOICES.xy + worldVoxelAddress(cell, WORLD_FAR_SHAPE, 0, 0);
    for (int corner = 0; corner < 4; corner++) {
        ivec2 offset = ivec2(corner % 2, corner / 2);
        gl_Position = vec4(vec2(pixel + offset) / float(WORLD_CAPTURE_SIDE) * 2.0 - 1.0, -0.999, 1.0);
        captureRoute = 3;
        sampleUv = vec2(0.0);
        sampleColour = vec3(1.0);
        captureMetadata = captureU = captureV = vec4(0.0);
        captureGroups = contribution;
        EmitVertex();
    }
    EndPrimitive();
}
#endif

void main() {
    captureRoute = 0;
    for (int index = 0; index < 3; index++) {
        vec4 clip = gl_in[index].gl_Position;
        clip.xy /= 0.05 + length(clip.xy) * 0.95;
        clip.z *= 0.2;
        vec2 logical = clip.xy / clip.w * 0.5 + 0.5;
        vec2 physical = (vec2(WORLD_CAPTURE_SOLAR.xy)
            + logical * vec2(WORLD_CAPTURE_SOLAR.zw)) / float(WORLD_CAPTURE_SIDE);
        clip.xy = (physical * 2.0 - 1.0) * clip.w;
        gl_Position = clip;
        captureRoute = 0;
        sampleUv = vertex[index].uv;
        sampleColour = vertex[index].colour;
        captureMetadata = vec4(0.0);
        captureU = captureV = vec4(0.0);
        captureGroups = vec4(0.0);
        EmitVertex();
    }
    EndPrimitive();
    vec3 normal = cross(vertex[1].position - vertex[0].position,
        vertex[2].position - vertex[0].position);
    float area = length(normal);
    if (area < 0.000001) return;
    normal /= area;
    int axis = worldSurfaceAxis(normal);
    int face = axis * 2 + int(normal[axis] < 0.0);
    WorldPosition centre = worldPosition(vertex[0].centre + vec3(0.001), cameraPosition);
    ivec3 farOrigin = worldAlignedOrigin(cameraPosition, WORLD_FAR_SHAPE, 1, 4);
    ivec3 farCell = worldGridCell(centre, farOrigin, 1);
    if (!worldCellValid(farCell, WORLD_FAR_SHAPE)) return;
    int material = int(round(vertex[0].material));
    if (material <= 0 || material >= 32768) return;
    // at_midBlock is byte quantized. Recover the canonical block origin before
    // measuring a plant's displacement or fitting the actual primitive UVs.
    vec3 blockOrigin = worldCameraRelative(WorldPosition(centre.block, vec3(0.0)), cameraPosition);
    vec3 a = vertex[0].position - blockOrigin;
    vec3 b = vertex[1].position - blockOrigin;
    vec3 c = vertex[2].position - blockOrigin;
    ivec2 boundSize = textureSize(gtexture, 0);
    WorldUv mapping = worldUvFromTriangle(worldSurfaceProjection(a, axis),
        worldSurfaceProjection(b, axis), worldSurfaceProjection(c, axis),
        worldAtlasUv(vertex[0].uv, spriteBounds, boundSize, atlasSize),
        worldAtlasUv(vertex[1].uv, spriteBounds, boundSize, atlasSize),
        worldAtlasUv(vertex[2].uv, spriteBounds, boundSize, atlasSize), false);
    int flags = 3;
    bool priorityTint = false;
    ivec3 offsetCode = ivec3(0);
#ifdef WORLD_MODEL_UV
    vec3 colour = vertex[0].colour;
    bool tinted = max(colour.r, max(colour.g, colour.b)) - min(colour.r, min(colour.g, colour.b)) > 0.001;
    bool hasTint;
    WorldModelOffset displacement;
    int hint;
    int condition;
    int modelFace = worldObservedModelFace(noisetex, material, face, a, b, c, mapping, tinted,
        hasTint, displacement, hint, condition);
    offsetCode = displacement.code;
    priorityTint = tinted || (modelFace >= 0 && worldModelFace(noisetex, modelFace).tint >= 0);
    mapping.tinted = priorityTint;
    bool tintKnown = !hasTint || priorityTint;
    bool offsetKnown = displacement.valid;
    flags = int(offsetKnown) + int(tintKnown) * 2;
#endif
    ivec3 nearOrigin = worldAlignedOrigin(cameraPosition, WORLD_NEAR_SHAPE, 2, 4);
    ivec3 nearCell = worldFloorDivide(worldGridCell(centre, nearOrigin, 2), 2) * 2;
    if (worldCellValid(nearCell, WORLD_NEAR_SHAPE)) {
        worldEmitRecord(worldCapturePixel(true, nearCell), ivec2(2), face, flags, priorityTint, offsetCode);
        worldEmitRecord(worldCapturePixel(true, nearCell + ivec3(0, 0, 1)), ivec2(2), face, flags, priorityTint, offsetCode);
    }
    worldEmitRecord(worldCapturePixel(false, farCell), ivec2(1), face, flags, priorityTint, offsetCode);
#ifdef WORLD_MODEL_UV
    worldEmitChoice(farCell, material, hint, condition);
#endif
    if (!mapping.valid) return;
#ifdef WORLD_MODEL_UV
    if (modelFace >= 0) {
        // Global face mappings use canonical coordinates; per-block mappings
        // below retain displaced coordinates for the observed near face.
        WorldUv canonicalMapping = mapping;
        vec2 offsetUv = worldSurfaceProjection(displacement.value, axis);
        canonicalMapping.u.z += dot(mapping.u.xy, offsetUv);
        canonicalMapping.v.z += dot(mapping.v.xy, offsetUv);
        ivec2 address = ivec2(modelFace % WORLD_CAPTURE_MATERIALS.z, modelFace / WORLD_CAPTURE_MATERIALS.z);
        worldEmitUv(WORLD_CAPTURE_MATERIALS.xy + address, canonicalMapping);
        WorldModelFace canonical = worldModelFace(noisetex, modelFace);
        float uLength = dot(canonical.u.xy, canonical.u.xy);
        float vLength = dot(canonical.v.xy, canonical.v.xy);
        if (uLength > 1e-10 && vLength > 1e-10) {
            float uScale = dot(mapping.u.xy, canonical.u.xy) / uLength;
            float vScale = dot(mapping.v.xy, canonical.v.xy) / vLength;
            WorldUv textureMapping = WorldUv(vec3(uScale, 0.0, canonicalMapping.u.z - uScale * canonical.u.z),
                vec3(0.0, vScale, canonicalMapping.v.z - vScale * canonical.v.z),
                uScale > 0.0 && vScale > 0.0, tinted);
            int textureRecord = WORLD_TEXTURE_UV_START + canonical.texture;
            address = ivec2(textureRecord % WORLD_CAPTURE_MATERIALS.z, textureRecord / WORLD_CAPTURE_MATERIALS.z);
            if (textureMapping.valid) worldEmitUv(WORLD_CAPTURE_MATERIALS.xy + address, textureMapping);
        }
    }
#else
    worldEmitUv(WORLD_CAPTURE_MATERIALS.xy
        + worldMaterialFaceAddress(material, face, WORLD_CAPTURE_MATERIALS.z), mapping);
#endif
    ivec3 blockCell = worldFloorDivide(nearCell, 2);
    if (worldCellValid(blockCell, WORLD_NEAR_SHAPE / 2)) {
        worldEmitUv(WORLD_CAPTURE_NEAR_FACES.xy + worldNearFaceAddress(blockCell, face), mapping);
    }
}
