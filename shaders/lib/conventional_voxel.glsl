/* Native shadow vertices write one block-center material to temporary C1.
 * Repeated vertices of the same block write identical values. No geometry
 * amplification, host world upload or per-light shadow rendering is needed.
 */
#ifndef SIMPLE_CONVENTIONAL_VOXEL_GLSL
#define SIMPLE_CONVENTIONAL_VOXEL_GLSL
#include "/lib/conventional_lpv.glsl"

#if ENABLE_COLOURED_LIGHTING == 1
layout(rgba16f) uniform image2D colorimg1;

vec4 lpvVoxelMaterial(int id) {
    if (id == 6000) return vec4(1.0, 0.46, 0.12, 2.0);
    if (id == 6001) return vec4(0.10, 0.65, 1.0, 2.0);
    if (id == 6002) return vec4(1.0, 0.05, 0.01, 2.0);
    if (id == 6003) return vec4(0.55, 0.95, 0.82, 2.0);
    if (id == 6004) return vec4(0.92, 0.85, 1.0, 2.0);
    if (id == 6005) return vec4(0.48, 1.0, 0.35, 2.0);
    if (id == 6006) return vec4(1.0, 0.58, 0.90, 2.0);
    if (id == 6007) return vec4(0.68, 0.20, 1.0, 2.0);
    if (id == 101) return vec4(1.0, 0.46, 0.12, 2.0);
    if (id == 102) return vec4(0.85, 0.80, 1.0, 2.0);
    if (id == 100 || id == 110) return vec4(0.90, 0.95, 1.0, 3.0);
    if (id >= 200 && id < 300) return vec4(0.85, 0.95, 0.75, 3.0);
    return vec4(0.0, 0.0, 0.0, 1.0);
}

void lpvCaptureVertex(vec3 centre, int id) {
    if (renderStage < 8 || renderStage > 16) return;
    ivec3 cell = ivec3(floor(centre + 0.001)) - lpvOrigin(cameraPosition);
    if (!lpvInside(cell)) return;
    int index = lpvIndex(cell);
    ivec2 size = imageSize(colorimg1);
    if (index >= size.x * size.y) return;
    imageStore(colorimg1, ivec2(index % size.x, index / size.x), lpvVoxelMaterial(id));
}
#endif
#endif
