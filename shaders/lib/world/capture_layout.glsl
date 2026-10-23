#ifndef SIMPLE_WORLD_CAPTURE_LAYOUT_GLSL
#define SIMPLE_WORLD_CAPTURE_LAYOUT_GLSL
#include "/lib/world/layout.glsl"

// Capture and resolved records share one slice order. A missing surface record
// remains unknown; it does not prove that the corresponding cell is air.
ivec2 worldCapturePixel(bool nearField, ivec3 cell) {
    ivec3 shape = nearField ? WORLD_NEAR_SHAPE : WORLD_FAR_SHAPE;
    if (!worldCellValid(cell, shape)) {
        return ivec2(-1);
    }
    ivec2 local = worldVoxelAddress(cell, shape, 0, 0);
    return (nearField ? WORLD_CAPTURE_NEAR.xy : WORLD_CAPTURE_FAR.xy) + local;
}

bool worldInsideRectangle(ivec2 pixel, ivec4 rectangle) {
    return all(greaterThanEqual(pixel, rectangle.xy))
        && all(lessThan(pixel, rectangle.xy + rectangle.zw));
}

ivec3 worldSliceCell(ivec2 pixel, ivec3 shape) {
    ivec2 slice = pixel / shape.xy;
    ivec3 cell = ivec3(pixel % shape.xy, slice.x + slice.y * 8);
    return worldCellValid(cell, shape) ? cell : ivec3(-1);
}
#endif
