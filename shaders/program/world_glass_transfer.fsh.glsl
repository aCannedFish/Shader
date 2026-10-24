#include "/lib/world/transmission.glsl"
#include "/lib/world/glass_cache.glsl"
#include "/lib/world/point_shadow.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
uniform sampler2D noisetex;
uniform int frameCounter;
layout(location=0) out vec4 result;

// Refresh the scheduled sources, reproject unchanged overlap, and compute new
// border samples immediately. A following local copy synchronizes the banks.
void main() {
    result = vec4(1.0, 1.0, 1.0, 0.0);
    ivec2 local = ivec2(gl_FragCoord.xy) - worldRegion(WORLD_REGION_GLASS_TRANSFER).xy;
    int side = WORLD_GI_SIZE + 2;
    int rows = (WORLD_GI_SIZE + 7) / 8;
    ivec2 tileSize = ivec2(side * 8, side * rows);
    ivec2 band = local / tileSize;
    int lightIndex = band.x + band.y * 8;
    int slot = lightIndex - 1;
    if (slot < 0 || slot >= WORLD_POINT_LIGHT_COUNT) return;
    WorldPointLight light = worldReadPointLight(colortex6, slot);
    if (!light.valid) return;
    ivec2 tile = local % tileSize;
    ivec2 slice = tile / side;
    ivec3 cell = ivec3(clamp(tile % side - 1, ivec2(0), ivec2(WORLD_GI_SIZE - 1)), slice.x + slice.y * 8);
    if (cell.z >= WORLD_GI_SIZE) return;
    ivec3 origin = worldGlassOrigin(colortex6, false);
    WorldPosition receiver = WorldPosition(origin + cell, vec3(0.5));
    WorldSample sample = worldRead(colortex6, receiver);
    if (sample.state == WORLD_SURFACE && (worldReadDefinition(colortex6, sample.material).flags & 256) != 0) return;
    bool history = worldLightHistoryValid(colortex6, frameCounter)
        && worldMatchedLightRank(colortex6, slot) >= 0;
    ivec3 oldCell = receiver.block - worldGlassOrigin(colortex6, true);
    bool overlap = all(greaterThanEqual(oldCell, ivec3(0))) && all(lessThan(oldCell, ivec3(WORLD_GI_SIZE)));
    if (history && overlap && !worldPointShadowScheduled(colortex6, slot, frameCounter + 1, false)) {
        result = texelFetch(colortex6, worldGlassCacheAddress(lightIndex, oldCell), 0);
        if (abs(result.w) > 0.5) return;
    }
    WorldTransmission transfer = worldTraceGlass(colortex6, noisetex, receiver, light.position);
    result = vec4(transfer.value, transfer.complete ? 1.0 : -1.0);
}
