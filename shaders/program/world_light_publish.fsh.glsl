#include "/lib/world/point_shadow.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
uniform vec3 cameraPosition;
uniform int frameCounter;
layout(location=0) out vec4 result;

// Light selection is renewed every frame. A new source does not wait for GI,
// a CPU scan, an insertion cycle, slot fade-out or an upload interval.
void main() {
    ivec4 rectangle = worldRegion(WORLD_REGION_LIGHT_SELECTION);
    ivec2 local = ivec2(gl_FragCoord.xy) - rectangle.xy;
    int record = local.x + local.y * rectangle.z;
    result = vec4(0.0);
    if (record == 0) result = vec4(905.0, WORLD_POINT_LIGHT_COUNT, 0.0, 0.0);
    if (record == 1) result = worldEncodeInt(frameCounter);
    if (record == 2) result = worldEncodeUint(worldReadGeneration(colortex6));
    if (record >= 3 && record < 6) result = worldEncodeInt(worldReadOrigin(colortex6, false)[record - 3]);
    if (record < WORLD_LIGHT_HEADER_SIZE) return;
    int slot = (record - WORLD_LIGHT_HEADER_SIZE) / 4;
    int word = (record - WORLD_LIGHT_HEADER_SIZE) % 4;
    if (slot >= WORLD_POINT_LIGHT_COUNT) return;
    int rank = worldStableLightRank(colortex6, slot, frameCounter);
    if (rank < 0) return;
    int leaf = worldRankedLightLeaf(colortex6, rank);
    if (leaf < 0) return;
    ivec3 cell = worldLightCell(leaf);
    ivec2 address = worldAtlasPixel(WORLD_REGION_FAR_OPTICS,
        worldVoxelAddress(cell, WORLD_FAR_SHAPE, 0, 0));
    ivec4 optics = ivec4(round(texelFetch(colortex6, address, 0)));
    int material = optics.x + optics.y * 256;
    WorldDefinition definition = worldReadDefinition(colortex6, material);
    float radius = WORLD_POINT_LIGHT_RADIUS * max(float(definition.emissionLevel) / 15.0, 0.25);
    if (word == 0) result = vec4(cell, radius);
    if (word == 1) result = vec4(definition.emission, definition.emissionLevel);
    if (word == 2) result = vec4(worldEmitterOffset(definition), 1.0);
    if (word == 3) {
        vec4 ranked = texelFetch(colortex6, worldRegion(WORLD_REGION_LIGHT_RANKED).xy + ivec2(rank, 0), 0);
        bool retained = worldLightHistoryValid(colortex6, frameCounter)
            && worldMatchedLightRank(colortex6, slot) == rank;
        vec4 previousMap = texelFetch(colortex6,
            worldPreviousLightPixel(WORLD_LIGHT_HEADER_SIZE + slot * 4 + 3), 0);
        bool sameState = int(round(previousMap.x + previousMap.y * 256.0)) == material;
        float mapped = retained && sameState ? previousMap.w : 0.0;
        if (retained && sameState && worldPointShadowScheduled(colortex6, slot, frameCounter, true)) mapped = 1.0;
        WorldPointLight light = WorldPointLight(WorldPosition(worldReadOrigin(colortex6, false) + cell,
            worldEmitterOffset(definition)), definition.emission, radius, float(definition.emissionLevel), true);
        bool refreshed = retained && sameState && worldPointShadowScheduled(colortex6, slot, frameCounter, true);
        bool dirty = (worldPointGeometryChanged(colortex6, light) || (retained && previousMap.z > 0.5)) && !refreshed;
        result = vec4(material % 256, material / 256, dirty ? 1.0 : 0.0, mapped);
    }
}
