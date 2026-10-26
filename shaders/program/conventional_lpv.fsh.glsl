/* Compact, camera-relative RGB diffusion. Each iteration shares the same
 * six neighbor reads across color channels. Current opaque voxels stop light;
 * transmitted voxels tint it. Header validation rejects stale/resized history.
 */
/* RENDERTARGETS: 8 */
#include "/lib/conventional_lpv.glsl"
layout(location=0) out vec4 result;
#if ENABLE_COLOURED_LIGHTING == 1
layout(rgba16f) uniform image2D colorimg1;
#endif

void main() {
    result = vec4(0.0);
#if ENABLE_COLOURED_LIGHTING == 1
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    if (all(equal(pixel, ivec2(0)))) {
        result = vec4(lpvShape().x, frameCounter % 1024, frameCounter / 1024, 1957.0);
        return;
    }
    int index = pixel.x + pixel.y * textureSize(colortex8, 0).x - 1;
    ivec3 shape = lpvShape();
    if (index < 0 || index >= shape.x * shape.y * shape.z) return;
    ivec3 cell = ivec3(index % shape.x, (index / shape.x) % shape.y, index / (shape.x * shape.y));
    ivec2 scratchSize = imageSize(colorimg1);
    vec4 voxel = imageLoad(colorimg1, ivec2(index % scratchSize.x, index / scratchSize.x));
    if (voxel.a == 1.0) {
        result.a = 1.0;
        return;
    }
    vec4 header = texelFetch(colortex8, ivec2(0), 0);
    vec3 light = vec3(0.0);
    if (lpvHeaderValid(header)) {
        bool sameFrame = lpvHeaderFrame(header) == frameCounter;
        ivec3 previous = cell + lpvOrigin(cameraPosition)
            - lpvOrigin(sameFrame ? cameraPosition : previousCameraPosition);
        light = lpvReadCell(previous);
        for (int face = 0; face < 6; face++) {
            ivec3 offset = ivec3(0);
            offset[face / 2] = face % 2 == 0 ? 1 : -1;
            light += lpvReadCell(previous + offset);
        }
        light *= 0.94 / 7.0;
    }
    if (voxel.a == 3.0) light *= voxel.rgb * voxel.rgb;
    if (voxel.a == 2.0) light += voxel.rgb * voxel.rgb;
    result = vec4(min(light, vec3(16.0)), voxel.a);
#endif
}
