#include "/lib/world/coordinates.glsl"
#include "/lib/world/types.glsl"
#include "/lib/world/static.glsl"
#include "/lib/world/history.glsl"
#include "/lib/world/capture_layout.glsl"
#include "/lib/world/coverage.glsl"
#include "/lib/world/uv.glsl"
#include "/lib/world/point_shadow.glsl"
#include "/lib/world/raw_packing.glsl"
#ifdef WORLD_PACKED_UV
#include "/lib/world/raw_uv.glsl"
#endif
#ifdef WORLD_PACKED_OBSERVATION
#include "/lib/world/raw_observation.glsl"
#include "/lib/world/attributes.glsl"
#endif
/* RENDERTARGETS: 6 */
/*
const int colortex6Format = RGBA16F;
*/
const bool colortex6Clear = false;
const vec4 shadowcolor0ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 shadowcolor1ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
uniform sampler2D shadowcolor0;
uniform sampler2D shadowcolor1;
uniform sampler2D colortex6;
uniform sampler2D noisetex;
#ifdef WORLD_ATLAS_PROBE
uniform sampler2D depthtex2;
#endif
uniform vec3 cameraPosition;
uniform int frameCounter;
layout(location=0) out vec4 result;

// Both banks receive current observations; removed or unloaded geometry cannot
// leave an old solid record. A missing observation is explicitly UNKNOWN.
void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    result = texelFetch(colortex6, pixel, 0);
    WorldFrame previous = worldPreviousFrame(colortex6);
    vec4 resourceStamp = worldStaticTexel(noisetex, WORLD_STATIC_SIZE.x * WORLD_STATIC_SIZE.y * WORLD_STATIC_SIZE.z - 1);
    uint epoch = worldFrameEpoch(previous, cameraPosition, frameCounter, resourceStamp);
    bool historyValid = previous.valid && epoch == previous.epoch;
    ivec4 coverage = worldRegion(WORLD_REGION_FAR_COVERAGE);
    if (worldInsideRectangle(pixel, coverage)) {
        ivec2 local = pixel - coverage.xy;
        vec4 captured = texelFetch(shadowcolor0, WORLD_CAPTURE_COVERAGE.xy + local, 0);
        bool submitted = captured.x > 0.0;
        int checksum = int(round(captured.y));
        int count = int(round(captured.z)) & 2047;
        vec4 oldCoverage = vec4(0.0);
        ivec3 cell = worldSliceCell(local, worldCoverageShape());
        if (historyValid && worldCellValid(cell, worldCoverageShape())) {
            ivec3 currentOrigin = worldAlignedOrigin(cameraPosition, WORLD_FAR_SHAPE, 1, 4);
            ivec3 block = worldCoverageOrigin(currentOrigin) + cell * 8;
            ivec2 oldPixel = worldCoverageAddress(block, previous.farOrigin);
            if (oldPixel.x >= 0) oldCoverage = texelFetch(colortex6, coverage.xy + oldPixel, 0);
        }
        float high = float(((checksum >> 11) & 1023) + 1);
        float low = float(checksum & 2047);
        bool domainChanged = historyValid ? submitted != (oldCoverage.x > 0.5) : submitted;
        bool animatedChanged = historyValid ? abs(oldCoverage.x) != high || oldCoverage.z != low
            || oldCoverage.w != float(count) : count > 0;
        result = vec4(submitted ? high : -high, float(int(domainChanged) | (int(animatedChanged) << 1)), low, count);
        return;
    }
    ivec4 pointRegion = worldRegion(WORLD_REGION_POINT_SHADOWS);
    if (worldInsideRectangle(pixel, pointRegion)) {
        ivec2 local = pixel - pointRegion.xy;
        ivec2 tile = local / WORLD_POINT_SHADOW_SIDE;
        int slot = (tile.x + tile.y * 24) / 6;
        if (slot < WORLD_POINT_LIGHT_COUNT && worldPointShadowScheduled(colortex6, slot, frameCounter, false)) {
            result = texelFetch(shadowcolor1, WORLD_CAPTURE_POINTS.xy + local, 0);
            result.r = 1.0 - result.r;
        }
        return;
    }
    // Freeze the previous selection before partial light producers change it.
    // Both banks then read the same identities during all hierarchy passes.
    ivec4 lightHistory = worldRegion(WORLD_REGION_LIGHT_PREVIOUS);
    if (worldInsideRectangle(pixel, lightHistory)) {
        ivec4 selection = worldRegion(WORLD_REGION_LIGHT_SELECTION);
        ivec2 local = pixel - lightHistory.xy;
        result = texelFetch(colortex6, selection.xy + local, 0);
        return;
    }
    // These observations are renewed from submitted geometry every frame.
    // Missing faces never inherit UVs from a previous resource atlas or owner.
    for (int field = 0; field < 2; field++) {
        bool nearField = field == 0;
        ivec4 rectangle = worldRegion(nearField ? WORLD_REGION_NEAR_FACES : WORLD_REGION_MATERIAL_FACES);
        if (!worldInsideRectangle(pixel, rectangle)) continue;
        ivec2 local = pixel - rectangle.xy;
        ivec2 rawPixel;
        int word;
        if (nearField) {
            rawPixel = WORLD_CAPTURE_NEAR_FACES.xy + ivec2(local.x / 3, local.y);
            word = local.x % 3;
        } else {
            int index = local.x + local.y * rectangle.z;
            int record = index / 3;
            rawPixel = WORLD_CAPTURE_MATERIALS.xy
                + ivec2(record % WORLD_CAPTURE_MATERIALS.z, record / WORLD_CAPTURE_MATERIALS.z);
            word = index % 3;
        }
#ifdef WORLD_PACKED_UV
        WorldUv mapping = worldRawDecodeUv(texelFetch(shadowcolor1, rawPixel, 0));
#else
        vec4 u = texelFetch(shadowcolor0, rawPixel, 0);
        vec4 v = texelFetch(shadowcolor1, rawPixel, 0);
        WorldUv mapping = WorldUv(u.xyz, v.xyz, u.w == 517.0 && (v.w == 517.0 || v.w == 518.0),
            v.w == 518.0);
#endif
        result = worldEncodeUvWord(mapping, word);
        return;
    }
#ifdef WORLD_PACKED_OBSERVATION
    ivec4 attributesRegion = worldRegion(WORLD_REGION_FAR_ATTRIBUTES);
    if (worldInsideRectangle(pixel, attributesRegion)) {
        result = vec4(0.0);
        ivec3 cell = worldSliceCell(pixel - attributesRegion.xy, WORLD_FAR_SHAPE);
        if (!worldCellValid(cell, WORLD_FAR_SHAPE)) return;
        WorldObservation observation = worldDecodeObservation(
            texelFetch(shadowcolor1, worldCapturePixel(false, cell), 0));
        if (observation.material <= 0) return;
        WorldDefinition observedDefinition = worldReadDefinition(colortex6, observation.material);
        if ((observedDefinition.flags & 8) != 0) {
            vec4 dynamic = texelFetch(shadowcolor0, worldCapturePixel(false, cell), 0);
            int checksum = int(round(dynamic.g));
            result = vec4(checksum & 2047, (checksum >> 11) & 2047, min(dynamic.b, 2047.0), 0.0);
            return;
        }
        ivec4 range = worldModelChoiceRange(noisetex, observation.material);
        ivec2 address = WORLD_CAPTURE_CHOICES.xy + worldVoxelAddress(cell, WORLD_FAR_SHAPE, 0, 0);
        vec4 accumulation = texelFetch(shadowcolor0, address, 0);
        int selection = 0;
        bool known = true;
        for (int index = 0; index < 6; index++) {
            if (index >= range.y) break;
            WorldChoiceGroup group = worldModelChoiceGroup(noisetex, range, index);
            int choice = worldDecodeChoice(accumulation, group);
            known = known && choice >= 0;
            selection += max(choice, 0) * group.radix;
        }
        int first = worldModelOffsetStart(noisetex, observation.material);
        ivec3 counts = ivec3(round(worldStaticTexel(noisetex, first).xyz));
        ivec3 code = observation.offsetCode;
        bool offsetValid = observation.offsetValid && worldDecodeModelOffset(noisetex,
            observation.material, code).valid;
        int offset = code.x + counts.x * (code.y + counts.y * code.z);
        int pose = offset + selection * counts.x * counts.y * counts.z;
        result = worldEncodeAttributes(observation.tint, pose, offsetValid, known, observation.tintValid);
        return;
    }
#endif
    // Descriptor input is a pack-owned resource, not a runtime CPU data feed.
    for (int field = 0; field < 2; field++) {
        int region = field == 0 ? WORLD_REGION_STATES : WORLD_REGION_SHAPES;
        ivec4 rectangle = worldRegion(region);
        if (worldInsideRectangle(pixel, rectangle)) {
            ivec2 local = pixel - rectangle.xy;
            int index = local.x + local.y * rectangle.z;
            result = worldStaticTexel(noisetex, index + (field == 0 ? 0 : WORLD_SHAPE_START));
            return;
        }
    }
    for (int field = 0; field < 4; field++) {
        bool nearField = field < 2;
        bool materialField = field % 2 == 0;
        int region = nearField
            ? (materialField ? WORLD_REGION_NEAR_MATERIAL : WORLD_REGION_NEAR_OPTICS)
            : (materialField ? WORLD_REGION_FAR_MATERIAL : WORLD_REGION_FAR_OPTICS);
        ivec4 rectangle = worldRegion(region);
        if (!worldInsideRectangle(pixel, rectangle)) continue;
        result = vec4(0.0);
        ivec3 shape = nearField ? WORLD_NEAR_SHAPE : WORLD_FAR_SHAPE;
        ivec3 cell = worldSliceCell(pixel - rectangle.xy, shape);
        ivec2 rawPixel = worldCapturePixel(nearField, cell);
        if (rawPixel.x < 0) return;
        ivec3 origin = worldAlignedOrigin(cameraPosition, shape, nearField ? 2 : 1, 4);
        ivec3 oldOrigin = nearField ? previous.nearOrigin : previous.farOrigin;
        ivec3 oldCell = worldPreviousCell(cell, origin, oldOrigin);
        int materialRegion = nearField ? WORLD_REGION_NEAR_MATERIAL : WORLD_REGION_FAR_MATERIAL;
        int opticsRegion = nearField ? WORLD_REGION_NEAR_OPTICS : WORLD_REGION_FAR_OPTICS;
        vec4 oldMaterial = vec4(0.0);
        vec4 oldOptics = vec4(0.0);
        if (historyValid && worldCellValid(oldCell, shape)) {
            ivec2 oldPixel = worldVoxelAddress(oldCell, shape, 0, 0);
            oldMaterial = texelFetch(colortex6, worldAtlasPixel(materialRegion, oldPixel), 0);
            oldOptics = texelFetch(colortex6, worldAtlasPixel(opticsRegion, oldPixel), 0);
        }
        vec4 raw = texelFetch(shadowcolor1, rawPixel, 0);
        int material;
        int face;
        bool observed;
        vec4 currentMaterial;
#ifdef WORLD_PACKED_OBSERVATION
        WorldObservation observation = worldDecodeObservation(raw);
        material = observation.material;
        face = observation.face;
        observed = material > 0;
        currentMaterial = vec4(observation.albedo, float(observation.light));
#else
        material = int(round(raw.x));
        face = int(round(raw.w)) - 17;
        observed = raw.w >= 16.5 && raw.w <= 22.5;
        currentMaterial = texelFetch(shadowcolor0, rawPixel, 0);
#endif
        vec4 accumulated = texelFetch(shadowcolor0, rawPixel, 0);
        bool anchored = false;
#ifdef WORLD_PACKED_OBSERVATION
        if (!nearField) {
            ivec2 rootPixel = WORLD_CAPTURE_CHOICES.xy + worldVoxelAddress(cell, WORLD_FAR_SHAPE, 0, 0);
            WorldObservation root = worldDecodeObservation(texelFetch(shadowcolor1, rootPixel, 0));
            anchored = root.material > 0;
            if (anchored) {
                material = root.material;
                if (!observed) {
                    currentMaterial = vec4(root.albedo, float(root.light));
                    face = root.face;
                }
                observed = true;
            }
        }
#endif
        if (!observed) {
            if (!nearField && !materialField) {
                ivec3 block = origin + cell;
                ivec2 covered = worldCoverageAddress(block, origin);
                bool submitted = covered.x >= 0 && texelFetch(shadowcolor0, WORLD_CAPTURE_COVERAGE.xy + covered, 0).x > 0.0;
                bool seeded = texelFetch(shadowcolor0, rawPixel, 0).x > 0.0;
                if (submitted && (seeded || oldOptics.w == float(WORLD_AIR))) {
                    bool runtime = (worldReadDefinition(colortex6, int(round(oldOptics.x + oldOptics.y * 256.0))).flags & 8) != 0;
                    result = vec4(0.0, 0.0, oldOptics.w > 1.5 ? (runtime ? 56.0 : 24.0) : 0.0, float(WORLD_AIR));
                    return;
                }
            }
            if (!materialField && oldOptics.w > 0.5) {
                bool runtime = (worldReadDefinition(colortex6, int(round(oldOptics.x + oldOptics.y * 256.0))).flags & 8) != 0;
                result.z = oldOptics.w > 1.5 ? (runtime ? 56.0 : 24.0) : 8.0;
            }
            return;
        }
        if (materialField) {
            result = currentMaterial;
        } else {
            int first = material * WORLD_STATE_STRIDE;
            WorldDefinition definition = worldDecodeDefinition(worldStaticTexel(noisetex, first),
                worldStaticTexel(noisetex, first + 1), worldStaticTexel(noisetex, first + 2));
            int legacy = definition.legacy;
            int state = legacy == 100 ? WORLD_WATER
                : definition.alphaType == 2 ? WORLD_TRANSMISSION : WORLD_SURFACE;
            result = vec4(material % 256, material / 256, face, state);
#ifdef WORLD_PACKED_OBSERVATION
            if ((definition.flags & 8) != 0 && (anchored || observation.offsetValid)) result.z += 1024.0;
#endif
            bool geometryChanged = any(notEqual(oldOptics.xy, result.xy)) || oldOptics.w != result.w;
            if (!nearField && (definition.flags & 8) != 0 && historyValid && worldCellValid(oldCell, shape)) {
                ivec2 oldAddress = worldRegion(WORLD_REGION_FAR_ATTRIBUTES).xy + worldVoxelAddress(oldCell, shape, 0, 0);
                vec4 oldSignature = texelFetch(colortex6, oldAddress, 0);
                int oldChecksum = int(round(oldSignature.x)) + int(round(oldSignature.y)) * 2048;
                geometryChanged = geometryChanged || oldChecksum != int(round(accumulated.g))
                    || abs(oldSignature.z - min(accumulated.b, 2047.0)) > 0.5;
            }
            if ((definition.flags & 8) != 0) result.z += 32.0;
            if (geometryChanged) result.z += 16.0;
            if (worldObservationChanged(oldMaterial, oldOptics, currentMaterial, result)) result.z += 8.0;
        }
        return;
    }
    // Integer origins and frame IDs are byte encoded for half-float precision.
    ivec4 header = worldRegion(WORLD_REGION_HEADER);
    if (!worldInsideRectangle(pixel, header)) return;
    result = vec4(0.0);
    ivec2 local = pixel - header.xy;
    if (local.y != 0) return;
    if (local.x == 0) result = worldEncodeUint(WORLD_LAYOUT_SIGNATURE);
    if (local.x == 1) result = worldEncodeInt(frameCounter);
    if (local.x == 8) result = worldEncodeUint(epoch);
    if (local.x >= 9 && local.x < 12) result = worldEncodeInt(int(floor(cameraPosition[local.x - 9])));
    if (local.x == 12) result = vec4(fract(cameraPosition), 1.0);
    if (local.x == 13) result = resourceStamp;
#ifdef WORLD_ATLAS_PROBE
    ivec2 atlasSize = textureSize(depthtex2, 0);
    if (local.x == 14) result = vec4(atlasSize, 515.0, 1.0);
    if (local.x >= 16 && local.x < 32) {
        int sampleIndex = local.x - 16;
        ivec2 texel = ivec2((sampleIndex * 73 + 17) % 256,
            (sampleIndex * 151 + 29) % 256) * atlasSize / 256;
        result = texelFetch(depthtex2, texel, 0);
    }
#endif
    if (local.x >= 2 && local.x < 8) {
        bool nearField = local.x < 5;
        ivec3 shape = nearField ? WORLD_NEAR_SHAPE : WORLD_FAR_SHAPE;
        ivec3 origin = worldAlignedOrigin(cameraPosition, shape, nearField ? 2 : 1, 4);
        int axis = nearField ? local.x - 2 : local.x - 5;
        result = worldEncodeInt(origin[axis]);
    }
}
