#include "/lib/world/lookup.glsl"
#include "/lib/world/coverage.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
layout(location=0) out vec4 result;

// Flood only the submitted terrain domain, retaining observed surface barriers.
// Solid interiors stay unknown behind their captured boundary; an uncompiled
// section never becomes air merely because it has no observation.
void main() {
    ivec4 rectangle = worldRegion(WORLD_REGION_FAR_OPTICS);
    ivec3 cell = worldSliceCell(ivec2(gl_FragCoord.xy) - rectangle.xy, WORLD_FAR_SHAPE);
    result = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0);
    if (!worldCellValid(cell, WORLD_FAR_SHAPE) || result.w != float(WORLD_UNKNOWN)) return;
    ivec3 origin = worldReadOrigin(colortex6, false);
    if (!worldSubmittedCoverage(colortex6, origin + cell, origin)) return;
    for (int face = 0; face < 6; face++) {
        ivec3 neighbour = cell;
        neighbour[face / 2] += face % 2 == 0 ? 1 : -1;
        if (!worldCellValid(neighbour, WORLD_FAR_SHAPE)) continue;
        ivec2 pixel = rectangle.xy + worldVoxelAddress(neighbour, WORLD_FAR_SHAPE, 0, 0);
        if (texelFetch(colortex6, pixel, 0).w == float(WORLD_AIR)) {
            result = vec4(0.0, 0.0, 0.0, float(WORLD_AIR));
            return;
        }
    }
}
