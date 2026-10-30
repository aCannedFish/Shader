#include "/settings.glsl"
// OptiFine J9 rejects a 1x1x1 local size while scanning the source.
layout(local_size_x=2) in;
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
const ivec3 workGroups = ivec3(1, 1, 1);
#else
const ivec3 workGroups = ivec3(0, 0, 0);
#endif
void main() {}
