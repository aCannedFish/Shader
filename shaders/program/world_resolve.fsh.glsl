#include "/lib/world/coordinates.glsl"
#include "/lib/world/types.glsl"
#include "/lib/world/static.glsl"
#include "/lib/world/history.glsl"
#include "/lib/world/capture_layout.glsl"
#include "/lib/world/uv.glsl"
#ifdef WORLD_PACKED_UV
#include "/lib/world/raw_uv.glsl"
#endif
/* RENDERTARGETS: 6 */
/*
const int colortex6Format = RGBA16F;
*/
const bool colortex6Clear = false;
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
        if (raw.w < 16.5 || raw.w > 22.5) {
            if (!materialField && oldOptics.w > 0.5) result.z = 8.0;
            return;
        }
        if (materialField) {
            result = texelFetch(shadowcolor0, rawPixel, 0);
        } else {
            int material = int(round(raw.x));
            int first = material * WORLD_STATE_STRIDE;
            WorldDefinition definition = worldDecodeDefinition(worldStaticTexel(noisetex, first),
                worldStaticTexel(noisetex, first + 1), worldStaticTexel(noisetex, first + 2));
            int legacy = definition.legacy;
            int state = legacy == 100 ? WORLD_WATER
                : definition.alphaType == 2 ? WORLD_TRANSMISSION : WORLD_SURFACE;
            result = vec4(material % 256, material / 256, round(raw.w) - 17.0, state);
            vec4 newMaterial = texelFetch(shadowcolor0, rawPixel, 0);
            if (worldObservationChanged(oldMaterial, oldOptics, newMaterial, result)) result.z += 8.0;
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
