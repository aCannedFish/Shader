#include "/lib/world/light_selection.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
uniform int frameCounter;
layout(location=0) out vec4 result;
// Cache old-to-new identities once instead of repeating nested searches.
void main() {
    int slot = int(gl_FragCoord.x) - worldRegion(WORLD_REGION_LIGHT_MATCHING).x;
    int rank = worldLightHistoryValid(colortex6, frameCounter) ? worldPreviousLightRank(colortex6, slot) : -1;
    result = vec4(float(rank + 1), 0.0, 0.0, 0.0);
}
