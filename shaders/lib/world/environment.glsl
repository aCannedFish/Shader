/* Geometry-derived environment records. Unknown columns never seed mist;
 * water immersion reads a native surface plane independently of camera view.
 */
#ifndef SIMPLE_WORLD_ENVIRONMENT_GLSL
#define SIMPLE_WORLD_ENVIRONMENT_GLSL
#include "/lib/world/lookup.glsl"
#include "/lib/world/static.glsl"
#include "/lib/world/storage.glsl"
#include "/lib/uniforms.glsl"

vec4 worldTerrainHeader(int index) {
    ivec3 origin = worldReadOrigin(colortex6, false);
    if (index == 0) return vec4(vec2(origin.xz) + 2.5 - cameraPosition.xz, 4.0, 2718.0);
    return vec4(float(WORLD_FAR_SHAPE.x / 4), mod(vec2(origin.xz) + 2.5, 1000.0), 1.0);
}

vec4 worldTerrainColumn(ivec2 column, int field) {
    ivec4 region = worldRegion(WORLD_REGION_ENVIRONMENT_COLUMNS);
    ivec2 size = ivec2(region.z / 2, region.w);
    if (any(lessThan(column, ivec2(0))) || any(greaterThanEqual(column, size))) return vec4(0.0);
    return texelFetch(colortex6, region.xy + ivec2(column.x * 2 + field, column.y), 0);
}

vec4 worldCameraWaterMedium() {
    return texelFetch(colortex6, worldRegion(WORLD_REGION_WATER_MEDIUM).xy, 0);
}

vec4 worldWaterColumn(ivec2 column, int word) {
    if (any(lessThan(column, ivec2(0))) || any(greaterThanEqual(column, WORLD_FAR_SHAPE.xz))) return vec4(0.0);
    return texelFetch(colortex6, worldRegion(WORLD_REGION_WATER_COLUMNS).xy
        + ivec2(column.x * 3 + word, column.y), 0);
}

vec4 worldGroundColumn(ivec2 column, int field) {
    if (any(lessThan(column, ivec2(0))) || any(greaterThanEqual(column, WORLD_FAR_SHAPE.xz))) return vec4(0.0);
    return texelFetch(colortex6, worldRegion(WORLD_REGION_GROUND_COLUMNS).xy
        + ivec2(column.x * 2 + field, column.y), 0);
}
#endif
