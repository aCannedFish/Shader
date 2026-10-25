#include "/lib/world/solar_parameters.glsl"
#include "/lib/world/coordinates.glsl"
#include "/lib/world/capture_layout.glsl"
#include "/lib/world/coverage.glsl"
#include "/lib/world/uv.glsl"
#include "/lib/world/atlas_uv.glsl"
#include "/lib/world/raw_uv.glsl"
#include "/lib/world/raw_observation.glsl"
#include "/lib/world/point_shadow.glsl"
#include "/lib/world/dynamic_identity.glsl"
#ifdef WORLD_MODEL_UV
#include "/lib/world/model_surface.glsl"
#include "/lib/world/model_choices.glsl"
uniform sampler2D noisetex;
#endif
layout(triangles) in;
#ifdef WORLD_FULL_RENDERER
layout(invocations=WORLD_CAPTURE_INVOCATIONS) in;
#else
layout(invocations=WORLD_POINT_SHADOW_INVOCATIONS) in;
#endif
layout(triangle_strip, max_vertices=91) out;
in WorldVertex {
    vec3 sectionOrigin;
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
uniform sampler2D colortex6;
uniform int frameCounter;
uniform int blockEntityId;
out vec2 sampleUv;
flat out int captureRoute;
flat out vec4 capturePayload;
vec2 dynamicSignature;

// A one-pixel record needs only a small triangle containing its pixel centre.
// Near-field 2x2 records retain quads to cover all four centres exactly.
void worldEmitPacket(ivec2 pixel, ivec2 size, float depth, int route, vec4 payload) {
    int vertices = route == 8 || (size.x == 1 && size.y == 1) ? 3 : 4;
    for (int corner = 0; corner < 4; corner++) {
        if (corner >= vertices) break;
        vec2 extent = route == 8 ? vec2(size) * 2.0 : vec2(1.01);
        vec2 offset = vertices == 3
            ? (corner == 0 ? vec2(0.0) : corner == 1 ? vec2(extent.x, 0.0) : vec2(0.0, extent.y))
            : vec2(corner % 2, corner / 2) * vec2(size);
        gl_Position = vec4((vec2(pixel) + offset) / float(WORLD_CAPTURE_SIDE) * 2.0 - 1.0, depth, 1.0);
        captureRoute = route;
        capturePayload = payload;
        sampleUv = route == 8 ? dynamicSignature : (vertex[0].uv + vertex[1].uv + vertex[2].uv) / 3.0;
#ifdef WORLD_SHADOW_DIAGNOSTIC
        if (route == 1) {
            bool headerValid = texelFetch(colortex6, worldLightTablePixel(0), 0).x == 905.0;
            int sourceFrame = worldDecodeInt(texelFetch(colortex6, worldLightTablePixel(1), 0));
            uvec2 mask = worldPointShadowMask(colortex6, frameCounter, false);
            int status = int(headerValid) + int(sourceFrame == frameCounter - 1) * 2
                + int(any(notEqual(mask, uvec2(0u)))) * 4;
            sampleUv = vec2(status, frameCounter - sourceFrame);
        }
#endif
        EmitVertex();
    }
    EndPrimitive();
}

// One submitted terrain section supplies all of its native terrain layers in
// the shadow pass. Coverage expires each frame and never crosses unsubmitted
// sections. The marker describes this renderer's geometry domain, not entities.
void worldEmitCoverage(ivec3 origin, bool emitter) {
    ivec3 first = worldFloorDivide(ivec3(vertex[0].sectionOrigin) - worldCoverageOrigin(origin), 8);
    ivec3 shape = worldCoverageShape();
    ivec2 low = max(first.xy, ivec2(0));
    ivec2 high = min(first.xy + 2, shape.xy);
    if (any(greaterThanEqual(low, high))) return;
    for (int slice = 0; slice < 2; slice++) {
        int z = first.z + slice;
        if (z < 0 || z >= shape.z) continue;
        ivec2 pixel = WORLD_CAPTURE_COVERAGE.xy + worldVoxelAddress(ivec3(low, z), shape, 0, 0);
        worldEmitPacket(pixel, high - low, -0.999, 5, vec4(1.0, 0.0, 0.0, emitter ? 1.0 : 0.0));
    }
}

void worldEmitUv(ivec2 pixel, WorldUv mapping) {
    worldEmitPacket(pixel, ivec2(1), -0.99, 2, worldRawEncodeUv(mapping));
}

// Rasterize submitted geometry into each selected light's cube map. A flat
// primitive plane reconstructs radial depth in the fragment stage; this keeps
// geometry output within native OpenGL 4.1 limits without another draw hook.
void worldEmitPointShadows(WorldPosition owner, vec3 normal, int material) {
    WorldDefinition definition = worldReadDefinition(colortex6, material);
    if (definition.alphaType == 2) return;
    uvec2 mask = worldPointShadowMask(colortex6, frameCounter, false);
    if (all(equal(mask, uvec2(0u)))) return;
    int first = gl_InvocationID == 0 ? 0 : 3 + (gl_InvocationID - 1) * 5;
    int last = first + (gl_InvocationID == 0 ? 3 : 5);
    int ordinal = 0;
    for (int slot = 0; slot < WORLD_POINT_LIGHT_COUNT; slot++) {
        if ((mask[slot / 32] & (1u << uint(slot % 32))) == 0u) continue;
        int selected = ordinal++;
        if (selected < first || selected >= last) continue;
        WorldPointLight light = worldReadPointLight(colortex6, slot);
        if (all(equal(owner.block, light.position.block))) continue;
        vec3 relative = worldCameraRelative(light.position, cameraPosition);
        vec3 rays[3];
        for (int index = 0; index < 3; index++) rays[index] = vertex[index].position - relative;
        float plane = dot(normal, rays[0]) / light.radius;
        if (abs(plane) < 1e-7 || abs(plane) > 1.0001) continue;
        for (int face = 0; face < 6; face++) {
            vec3 clip[3];
            for (int index = 0; index < 3; index++) clip[index] = worldPointFaceClip(face, rays[index]);
            if (max(clip[0].z, max(clip[1].z, clip[2].z)) <= 0.02) continue;
            bool outside = false;
            for (int axis = 0; axis < 2; axis++) {
                outside = outside || (clip[0][axis] > clip[0].z && clip[1][axis] > clip[1].z && clip[2][axis] > clip[2].z)
                    || (clip[0][axis] < -clip[0].z && clip[1][axis] < -clip[1].z && clip[2][axis] < -clip[2].z);
            }
            if (outside) continue;
            int tile = slot * 6 + face;
            ivec2 corner = WORLD_CAPTURE_POINTS.xy
                + ivec2(tile % 24, tile / 24) * WORLD_POINT_SHADOW_SIDE;
            float inner = float(WORLD_POINT_SHADOW_SIDE - 2);
            vec2 middle = (vec2(corner) + 1.0 + inner * 0.5) / float(WORLD_CAPTURE_SIDE) * 2.0 - 1.0;
            float near = 0.02;
            float a = (light.radius + near) / (light.radius - near);
            float b = -2.0 * light.radius * near / (light.radius - near);
            for (int index = 0; index < 3; index++) {
                gl_Position = vec4(middle * clip[index].z + clip[index].xy * inner / float(WORLD_CAPTURE_SIDE),
                    a * clip[index].z + b, clip[index].z);
                captureRoute = 4;
                capturePayload = vec4(normal, worldShadowPlanePayload(plane, tile));
                sampleUv = vertex[index].uv;
                EmitVertex();
            }
            EndPrimitive();
        }
    }
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
    worldEmitPacket(pixel, ivec2(1), -0.999, 3, contribution);
}
#endif

// An order-independent, quantized geometry checksum detects animated changes
// without treating lighting or camera motion as a shadow-geometry edit.
uint worldDynamicVertexHash(vec3 relative) {
    WorldPosition point = worldPosition(relative, cameraPosition);
    uvec3 quantizedPosition = uvec3(point.block) * 1024u + uvec3(round(point.fraction * 1024.0));
    uint hash = quantizedPosition.x * 1664525u ^ quantizedPosition.y * 1013904223u ^ quantizedPosition.z * 2246822519u;
    hash ^= hash >> 16u;
    hash *= 0x7feb352du;
    hash ^= hash >> 15u;
    hash *= 0x846ca68bu;
    return hash ^ (hash >> 16u);
}

#ifdef WORLD_PLANAR_REFLECTION
#include "/lib/world/planar_capture.glsl"
#endif

#ifdef WORLD_FULL_RENDERER
// One bounded invocation captures environmental planes. It emits at most one
// three-vertex record per source triangle, keeping the existing invocation's
// 91-vertex budget intact and avoiding per-column vertical volume scans.
void worldEmitEnvironment() {
    int material = int(round(vertex[0].material));
    if (material <= 0 || material >= 32768) return;
    int first = material * WORLD_STATE_STRIDE;
    WorldDefinition definition = worldDecodeDefinition(worldStaticTexel(noisetex, first),
        worldStaticTexel(noisetex, first + 1), worldStaticTexel(noisetex, first + 2));
    if ((definition.flags & 8) != 0) return;
    vec3 normal = cross(vertex[1].position - vertex[0].position,
        vertex[2].position - vertex[0].position);
    float area = length(normal);
    if (area <= 0.000001) return;
    normal /= area;
    if (abs(normal.y) < 0.1) return;
    WorldPosition owner = worldPosition(vertex[0].centre + vec3(0.001), cameraPosition);
    ivec3 origin = worldAlignedOrigin(cameraPosition, WORLD_FAR_SHAPE, 1, 4);
    ivec2 column = owner.block.xz - origin.xz;
    if (any(lessThan(column, ivec2(0))) || any(greaterThanEqual(column, WORLD_FAR_SHAPE.xz))) return;
    bool tree = worldStaticTexel(noisetex, 140000 + material).r > 0.5;
    vec3 corner = vertex[0].position + cameraPosition;
    float height = corner.y - dot(normal.xz,
        vec2(owner.block.xz) + 0.5 - corner.xz) / normal.y;
    // Full cubes have exact logical planes. Avoid carrying shadow-camera
    // sub-block translation into the environmental height field.
    if ((definition.flags & 256) != 0 && abs(normal.y) > 0.999) {
        height = float(owner.block.y + (normal.y > 0.0 ? 1 : 0));
    }
    if (tree && normal.y > 0.1) {
        float top = float(owner.block.y + 1);
        worldEmitPacket(WORLD_CAPTURE_ENVIRONMENT_CANOPY.xy + column / 4, ivec2(1),
            -0.99 - top * 0.00001, 13, vec4(top, column % 4, 1.0));
        return;
    }
    bool water = definition.legacy == 100;
    if (definition.alphaType != 0 && definition.alphaType != 2 && !water) return;
    int field = normal.y > 0.0 ? 0 : 1;
    if (field == 1 && (water || height <= cameraPosition.y + 0.01)) return;
    float priority = field == 0 ? -0.99 - height * 0.00001
        : -0.999 + min(height - cameraPosition.y, 128.0) * 0.0001;
    worldEmitPacket(WORLD_CAPTURE_ENVIRONMENT_GROUND.xy + ivec2(column.x * 2 + field, column.y),
        ivec2(1), priority, 13, vec4(height, vertex[0].light, 0.0, 1.0));
}
#endif

void main() {
#ifdef WORLD_PLANAR_REFLECTION
    if (gl_InvocationID == WORLD_POINT_SHADOW_INVOCATIONS - 1) {
        worldEmitPlanar();
        return;
    }
#endif
#ifdef WORLD_FULL_RENDERER
    if (gl_InvocationID == WORLD_POINT_SHADOW_INVOCATIONS) {
        worldEmitEnvironment();
        return;
    }
#endif
    if (gl_InvocationID > 0) {
        uvec2 mask = worldPointShadowMask(colortex6, frameCounter, false);
        int count = worldShadowMaskCount(mask.x) + worldShadowMaskCount(mask.y);
        if (count <= 3 + (gl_InvocationID - 1) * 5) return;
    }
    int sourceMaterial = int(round(vertex[0].material));
    WorldDefinition sourceDefinition = worldReadDefinition(colortex6, sourceMaterial);
    int nativeMaterial = 0;
    if (blockEntityId > 0 || sourceMaterial == 0) {
        nativeMaterial = worldDynamicMaterial(colortex6, gtexture,
            vertex[0].position, vertex[1].position, vertex[2].position,
            vertex[0].uv, vertex[1].uv, vertex[2].uv);
        bool identifiedConduit = (sourceDefinition.flags & 8) != 0
            && ((sourceDefinition.flags >> 13) & 15) == 1;
        if (nativeMaterial > 0 && !identifiedConduit) {
            sourceMaterial = nativeMaterial;
            sourceDefinition = worldReadDefinition(colortex6, sourceMaterial);
        }
    }
    bool dynamic = blockEntityId > 0 || nativeMaterial > 0;
    // Beam/text effects attached to terrain-model block entities are not
    // collision geometry. Animated block models use their actual triangles.
    if (dynamic && ((sourceDefinition.flags & 8) == 0 || ((sourceDefinition.flags >> 13) & 15) == 2)) return;
    if (dynamic && ((sourceDefinition.flags >> 13) & 15) == 4) {
        float span = max(vertex[0].position.y, max(vertex[1].position.y, vertex[2].position.y))
            - min(vertex[0].position.y, min(vertex[1].position.y, vertex[2].position.y));
        if (span > 1.5) return;
    }
    if (gl_InvocationID > 0) {
        vec3 normal = cross(vertex[1].position - vertex[0].position, vertex[2].position - vertex[0].position);
        float area = length(normal);
        if (area < 0.000001) return;
        WorldPosition owner = dynamic
            ? worldPosition((vertex[0].position + vertex[1].position + vertex[2].position) / 3.0, cameraPosition)
            : worldPosition(vertex[0].centre + vec3(0.001), cameraPosition);
        worldEmitPointShadows(owner, normal / area, sourceMaterial);
        return;
    }
    captureRoute = 0;
#ifdef WORLD_FULL_RENDERER
    vec3 solarA = gl_in[0].gl_Position.xyz / gl_in[0].gl_Position.w;
    vec3 solarB = gl_in[1].gl_Position.xyz / gl_in[1].gl_Position.w;
    vec3 solarC = gl_in[2].gl_Position.xyz / gl_in[2].gl_Position.w;
    vec3 solarPlane = cross(solarB - solarA, solarC - solarA);
    float solarLength = length(solarPlane);
    solarPlane /= max(solarLength, 1e-20);
    float solarDistance = dot(solarPlane, solarA);
    int caster = sourceDefinition.emissionLevel > 0 ? 1
        : (sourceDefinition.flags & 128) != 0 ? 3
        : sourceDefinition.alphaType == 2 ? 2
        : sourceDefinition.legacy >= 200 && sourceDefinition.legacy <= 204 ? 4 : 0;
    float planePayload = uintBitsToFloat((floatBitsToUint(solarDistance) & ~7u) | uint(caster));
#endif
    for (int index = 0; index < 3; index++) {
        vec4 clip = gl_in[index].gl_Position;
        clip.xy /= (1.0 - SHADOW_MAP_BIAS) + length(clip.xy) * SHADOW_MAP_BIAS;
#ifndef WORLD_FULL_RENDERER
        clip.z *= 0.2;
#endif
        vec2 logical = clip.xy / clip.w * 0.5 + 0.5;
        vec2 physical = (vec2(WORLD_CAPTURE_SOLAR.xy)
            + logical * vec2(WORLD_CAPTURE_SOLAR.zw)) / float(WORLD_CAPTURE_SIDE);
        clip.xy = (physical * 2.0 - 1.0) * clip.w;
        gl_Position = clip;
        captureRoute = 0;
        sampleUv = vertex[index].uv;
#ifdef WORLD_FULL_RENDERER
        capturePayload = vec4(solarPlane, planePayload);
#else
        capturePayload = vec4(0.0);
#endif
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
    if (dynamic) {
        WorldPosition owner = worldPosition((vertex[0].position + vertex[1].position + vertex[2].position) / 3.0, cameraPosition);
        worldEmitPointShadows(owner, normal, sourceMaterial);
        vec3 minimum = min(vertex[0].position, min(vertex[1].position, vertex[2].position));
        vec3 maximum = max(vertex[0].position, max(vertex[1].position, vertex[2].position));
        ivec3 origin = worldAlignedOrigin(cameraPosition, WORLD_FAR_SHAPE, 1, 4);
        ivec3 low = worldPosition(minimum + vec3(0.0001), cameraPosition).block - origin;
        ivec3 high = worldPosition(maximum - vec3(0.0001), cameraPosition).block - origin;
        // A zero-thickness face on a voxel boundary belongs to the inward
        // side. The conservative envelope is occupancy, never a guessed box hit.
        for (int component = 0; component < 3; component++) {
            if (high[component] < low[component]) {
                low[component] = high[component] = owner.block[component] - origin[component];
            }
        }
        low = max(low, ivec3(0));
        high = min(high, WORLD_FAR_SHAPE - 1);
        if (any(greaterThan(low, high)) || high.z - low.z >= 8) return;
        vec2 texcoord = (vertex[0].uv + vertex[1].uv + vertex[2].uv) / 3.0;
        vec3 tint = (vertex[0].colour + vertex[1].colour + vertex[2].colour) / 3.0;
        vec3 albedo = pow(max(textureLod(gtexture, texcoord, 0.0).rgb * tint, vec3(0.0)), vec3(2.2));
        bool anchor = false;
        WorldPosition emitter = owner;
        float verticalSpan = maximum.y - minimum.y;
        int kind = (sourceDefinition.flags >> 13) & 15;
        vec2 footprint = maximum.xz - minimum.xz;
        if (kind == 8 && normal.y < -0.9999 && verticalSpan < 0.0001
            && all(lessThan(abs(footprint - vec2(0.875)), vec2(0.0001)))) {
            float floorPlane = minimum.y + cameraPosition.y;
            anchor = abs(floorPlane - round(floorPlane)) < 0.0005;
            // The recovered bottom plane can lie a few float ULPs below the
            // integer boundary. Choose the interior side instead of the floor.
            emitter = worldPosition((vertex[0].position + vertex[1].position + vertex[2].position) / 3.0
                + vec3(0.0, 0.002, 0.0), cameraPosition);
        }
        if (kind == 4 && normal.y > 0.9999 && verticalSpan < 0.0001) {
            anchor = true;
            emitter = worldPosition((vertex[0].position + vertex[1].position + vertex[2].position) / 3.0
                - vec3(0.0, 0.001, 0.0), cameraPosition);
        }
        if (kind == 1) {
            // Native conduit parts are co-centred cubes (6/8/16 model units)
            // plus a small eye quad. Cube-centre reconstruction stays inside
            // the owning block throughout their native rotation/bob range.
            // Texture UVs are atlas-remapped and cannot identify the cube face.
            vec3 ab = vertex[1].position - vertex[0].position;
            vec3 bc = vertex[2].position - vertex[1].position;
            vec3 ac = vertex[2].position - vertex[0].position;
            vec3 lengths = vec3(dot(ab, ab), dot(bc, bc), dot(ac, ac));
            float side = min(lengths.x, min(lengths.y, lengths.z));
            float diagonal = max(lengths.x, max(lengths.y, lengths.z));
            if (side > 0.0001 && abs(diagonal - 2.0 * side) < side * 0.001) {
                vec3 midpoint = lengths.x >= lengths.y && lengths.x >= lengths.z
                    ? (vertex[0].position + vertex[1].position) * 0.5
                    : lengths.y >= lengths.z ? (vertex[1].position + vertex[2].position) * 0.5
                    : (vertex[0].position + vertex[2].position) * 0.5;
                emitter = worldPosition(midpoint - normal * sqrt(side) * 0.5, cameraPosition);
                anchor = true;
            }
        }
        if (anchor && gl_PrimitiveIDIn % 2 == 0) {
            ivec3 emitterCell = emitter.block - origin;
            if (worldCellValid(emitterCell, WORLD_FAR_SHAPE)) {
                vec4 root = worldEncodeObservation(WorldObservation(sourceMaterial, face,
                    int(round(vertex[0].light)), ivec3(0), true, false, tint, albedo));
                ivec2 pixel = WORLD_CAPTURE_CHOICES.xy + worldVoxelAddress(emitterCell, WORLD_FAR_SHAPE, 0, 0);
                // This attachment is unused by static choice accumulation.
                // Repeated shell/wind observations overwrite the same identity.
                worldEmitPacket(pixel, ivec2(1), -0.9995, 9, root);
            }
        }
        uint checksum = worldDynamicVertexHash(vertex[0].position)
            + worldDynamicVertexHash(vertex[1].position) + worldDynamicVertexHash(vertex[2].position);
        dynamicSignature = vec2(float(checksum & 255u), 0.0);
        ivec2 coveragePixel = worldCoverageAddress(owner.block, origin);
        if (coveragePixel.x >= 0) {
            worldEmitPacket(WORLD_CAPTURE_COVERAGE.xy + coveragePixel, ivec2(1), -0.999, 10,
                vec4(0.0, dynamicSignature.x, 1.0, sourceDefinition.emissionLevel > 0 ? 1.0 : 0.0));
        }
        ivec2 extent = high.xy - low.xy + 1;
        if (any(greaterThan(extent, ivec2(16)))) return;
        // Invalid tint fields are available for the proxy rectangle bounds.
        // Its actual sampled colour is preserved separately in the albedo.
        vec3 bounds = vec3(low.xy, (extent.x - 1) + (extent.y - 1) * 16) / 255.0;
        vec4 packet = worldEncodeObservation(WorldObservation(sourceMaterial, face,
            int(round(vertex[0].light)), ivec3(0), false, false, bounds, albedo));
        for (int slice = 0; slice < 8; slice++) {
            int z = low.z + slice;
            if (z > high.z) break;
            worldEmitPacket(worldCapturePixel(false, ivec3(low.xy, z)), high.xy - low.xy + 1,
                -0.97, 8, packet);
        }
        return;
    }
    WorldPosition centre = worldPosition(vertex[0].centre + vec3(0.001), cameraPosition);
    ivec3 farOrigin = worldAlignedOrigin(cameraPosition, WORLD_FAR_SHAPE, 1, 4);
    // Water interfaces need only an X/Z domain. A deep camera may have the
    // surface above the 3D field; capture the native plane before that clipping.
    if (sourceDefinition.legacy == 100 && normal.y > 0.1) {
        ivec2 column = centre.block.xz - farOrigin.xz;
        if (all(greaterThanEqual(column, ivec2(0)))
            && all(lessThan(column, WORLD_FAR_SHAPE.xz))) {
            vec2 slope = -normal.xz / normal.y;
            vec3 corner = vertex[0].position + cameraPosition;
            float height = corner.y + dot(slope, vec2(centre.block.xz) + 0.5 - corner.xz);
            float atEye = height + dot(slope, fract(cameraPosition.xz) - 0.5);
            float separation = atEye >= cameraPosition.y ? atEye - cameraPosition.y
                : 64.0 + cameraPosition.y - atEye;
            float priority = -0.999 + min(separation, 128.0) * 0.0001;
            float sky = floor(vertex[0].light / 16.0);
            worldEmitPacket(WORLD_CAPTURE_WATER_COLUMNS.xy + column, ivec2(1), priority,
                12, vec4(height, slope, sky + 1.0));
        }
    }
    ivec3 farCell = worldGridCell(centre, farOrigin, 1);
    if (!worldCellValid(farCell, WORLD_FAR_SHAPE)) return;
    int material = int(round(vertex[0].material));
    if (material <= 0 || material >= 32768) return;
    worldEmitCoverage(farOrigin, sourceDefinition.emissionLevel > 0);
    worldEmitPointShadows(centre, normal, material);
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
    vec2 centroidUv = (vertex[0].uv + vertex[1].uv + vertex[2].uv) / 3.0;
    vec3 colourValue = (vertex[0].colour + vertex[1].colour + vertex[2].colour) / 3.0;
    vec3 albedo = pow(max(textureLod(gtexture, centroidUv, 0.0).rgb * colourValue, vec3(0.0)), vec3(2.2));
    vec4 observation = worldEncodeObservation(WorldObservation(material, face, int(round(vertex[0].light)),
        offsetCode, (flags & 1) != 0, (flags & 2) != 0, colourValue, albedo));
    float depth = -0.98 + float(face) * 0.0001 - (priorityTint ? 0.001 : 0.0);
    ivec3 nearOrigin = worldAlignedOrigin(cameraPosition, WORLD_NEAR_SHAPE, 2, 4);
    ivec3 nearCell = worldFloorDivide(worldGridCell(centre, nearOrigin, 2), 2) * 2;
    if (worldCellValid(nearCell, WORLD_NEAR_SHAPE)) {
        worldEmitPacket(worldCapturePixel(true, nearCell), ivec2(2), depth, 1, observation);
        worldEmitPacket(worldCapturePixel(true, nearCell + ivec3(0, 0, 1)), ivec2(2), depth, 1, observation);
    }
    worldEmitPacket(worldCapturePixel(false, farCell), ivec2(1), depth, 1, observation);
    // Fluid surfaces have no baked model UV/choice records. This also bounds
    // the extra interface packet without increasing the 91-vertex GS limit.
    if (sourceDefinition.legacy == 100) return;
#ifdef WORLD_MODEL_UV
    worldEmitChoice(farCell, material, hint, condition);
    if (modelFace >= 0 && worldModelFace(noisetex, modelFace).airSeed && abs(normal[axis]) > 0.9999) {
        ivec3 neighbour = farCell + ivec3(round(normal));
        if (worldCellValid(neighbour, WORLD_FAR_SHAPE)) {
            worldEmitPacket(worldCapturePixel(false, neighbour), ivec2(1), 0.9, 5, vec4(1.0, 0.0, 0.0, 0.0));
        }
    }
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
