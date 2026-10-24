#ifndef SIMPLE_WORLD_COVERAGE_GLSL
#define SIMPLE_WORLD_COVERAGE_GLSL
#include "/lib/world/capture_layout.glsl"

// J9 rebases X/Z by multiples of 1000, which preserve the native section's
// eight-block alignment. Eight-block coverage cells fit both possible phases
// of a sixteen-block section without assuming an absolute world origin.
ivec3 worldCoverageOrigin(ivec3 farOrigin) {
    return worldFloorDivide(farOrigin, 8) * 8;
}

ivec3 worldCoverageShape() {
    return WORLD_FAR_SHAPE / 8 + 2;
}

ivec2 worldCoverageAddress(ivec3 block, ivec3 farOrigin) {
    ivec3 cell = worldFloorDivide(block - worldCoverageOrigin(farOrigin), 8);
    return worldVoxelAddress(cell, worldCoverageShape(), 0, 0);
}

bool worldSubmittedCoverage(sampler2D data, ivec3 block, ivec3 farOrigin) {
    ivec2 local = worldCoverageAddress(block, farOrigin);
    if (local.x < 0) return false;
    return texelFetch(data, worldRegion(WORLD_REGION_FAR_COVERAGE).xy + local, 0).x > 0.5;
}
#endif
