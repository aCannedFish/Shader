#include "/lib/world/lookup.glsl"
#include "/lib/world/coverage.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
layout(location=0) out vec4 result;

// Collapse geometric edits into eight-block bins. Shadow scheduling reads this
// small field; light-level changes alone do not invalidate every nearby map.
void main() {
    ivec4 rectangle = worldRegion(WORLD_REGION_FAR_COVERAGE);
    ivec3 cell = worldSliceCell(ivec2(gl_FragCoord.xy) - rectangle.xy, worldCoverageShape());
    result = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0);
    if (!worldCellValid(cell, worldCoverageShape()) || result.y > 0.5 || result.x < 0.5) return;
    ivec3 farOrigin = worldReadOrigin(colortex6, false);
    ivec3 first = worldCoverageOrigin(farOrigin) + cell * 8 - farOrigin;
    for (int index = 0; index < 512; index++) {
        ivec3 voxel = first + ivec3(index % 8, (index / 8) % 8, index / 64);
        if (!worldCellValid(voxel, WORLD_FAR_SHAPE)) continue;
        ivec2 pixel = worldAtlasPixel(WORLD_REGION_FAR_OPTICS, worldVoxelAddress(voxel, WORLD_FAR_SHAPE, 0, 0));
        if ((int(round(texelFetch(colortex6, pixel, 0).z)) & 16) != 0) {
            result.y = 1.0;
            return;
        }
    }
}
