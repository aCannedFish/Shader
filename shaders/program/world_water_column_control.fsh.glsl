/* Publish the horizontal origin only after its reprojected columns are ready. */
/* RENDERTARGETS: 6 */
#include "/lib/world/environment.glsl"
layout(location=0) out vec4 result;

void main() {
    int word = int(gl_FragCoord.x) - worldRegion(WORLD_REGION_WATER_COLUMN_CONTROL).x;
    ivec3 origin = worldReadOrigin(colortex6, false);
    if (word == 0) result = worldEncodeInt(origin.x);
    if (word == 1) result = worldEncodeInt(origin.z);
    if (word == 2) result = worldEncodeUint(worldReadGeneration(colortex6));
    if (word == 3) result = vec4(0.0, 0.0, 0.0, 1661.0);
}
