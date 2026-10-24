#include "/lib/world/lookup.glsl"
#include "/lib/world/coverage.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
uniform sampler2D shadowcolor0;
layout(location=0) out vec4 result;

// Collapse geometric edits into eight-block bins. Shadow scheduling reads this
// small field; light-level changes alone do not invalidate every nearby map.
void main() {
    ivec4 rectangle = worldRegion(WORLD_REGION_FAR_COVERAGE);
    ivec3 cell = worldSliceCell(ivec2(gl_FragCoord.xy) - rectangle.xy, worldCoverageShape());
    result = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0);
    if (!worldCellValid(cell, worldCoverageShape())) return;
    bool nearEmitter = false;
    for (int z = -2; z <= 2 && !nearEmitter; z++) {
        for (int y = -2; y <= 2 && !nearEmitter; y++) {
            for (int x = -2; x <= 2; x++) {
                ivec3 source = cell + ivec3(x, y, z);
                if (!worldCellValid(source, worldCoverageShape())) continue;
                ivec2 pixel = WORLD_CAPTURE_COVERAGE.xy + worldVoxelAddress(source, worldCoverageShape(), 0, 0);
                if (texelFetch(shadowcolor0, pixel, 0).w > 0.5) { nearEmitter = true; break; }
            }
        }
    }
    if (nearEmitter) result.y = float(int(round(result.y)) | 4);
    if ((int(round(result.y)) & 3) == 3 || result.x < 0.5) return;
    ivec3 farOrigin = worldReadOrigin(colortex6, false);
    ivec3 first = worldCoverageOrigin(farOrigin) + cell * 8 - farOrigin;
    for (int index = 0; index < 512; index++) {
        ivec3 voxel = first + ivec3(index % 8, (index / 8) % 8, index / 64);
        if (!worldCellValid(voxel, WORLD_FAR_SHAPE)) continue;
        ivec2 pixel = worldAtlasPixel(WORLD_REGION_FAR_OPTICS, worldVoxelAddress(voxel, WORLD_FAR_SHAPE, 0, 0));
        int flags = int(round(texelFetch(colortex6, pixel, 0).z));
        if ((flags & 16) != 0) {
            result.y = float(int(round(result.y)) | ((flags & 32) != 0 ? 2 : 1));
            if ((int(round(result.y)) & 3) == 3) return;
        }
    }
}
