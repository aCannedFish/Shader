#include "/lib/world/light_selection.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
uniform vec3 cameraPosition;
uniform int frameCounter;
layout(location=0) out vec4 result;
// Extract each selected rank once, then share it with slot assignment.
void main() {
    int rank = int(gl_FragCoord.x) - worldRegion(WORLD_REGION_LIGHT_RANKED).x;
    vec4 selected = worldSelectLight(colortex6, rank, cameraPosition, frameCounter);
    uint id = uint(round(selected.z));
    result = vec4(id & 255u, (id >> 8u) & 255u, (id >> 16u) & 255u, selected.w);
}
