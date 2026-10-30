#include "/lib/conventional_lpv.glsl"
layout(local_size_x=256) in;
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
#if COLOURED_VOLUME_SIZE == 32
const ivec3 workGroups = ivec3(64, 1, 1);
#elif COLOURED_VOLUME_SIZE == 48
const ivec3 workGroups = ivec3(216, 1, 1);
#elif COLOURED_VOLUME_SIZE == 64
const ivec3 workGroups = ivec3(512, 1, 1);
#else
const ivec3 workGroups = ivec3(1728, 1, 1);
#endif
#else
const ivec3 workGroups = ivec3(0, 0, 0);
#endif
void main() {
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
    int index = int(gl_GlobalInvocationID.x);
    ivec2 size = imageSize(colorimg5);
    ivec2 pixel = ivec2(index % size.x, index / size.x);
    ivec3 shape = lpvShape();
    int cells = shape.x * shape.y * shape.z;
    if (all(lessThan(pixel, size)) && index < cells) {
        imageStore(colorimg5, pixel, uvec4(0u));
        imageStore(colorimg5, pixel + ivec2(0, cells / size.x), uvec4(0u));
    }
#endif
}
