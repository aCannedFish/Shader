#include "/lib/world/point_shadow.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
uniform int frameCounter;
layout(location=0) out vec4 result;

// Publish next frame's small update list once. Geometry shaders then read three
// identities instead of running a source-selection scan for every triangle.
void main() {
    uvec2 mask = uvec2(0u);
    for (int slot = 0; slot < WORLD_POINT_LIGHT_COUNT; slot++) {
        if (worldPointShadowScheduledCandidate(colortex6, slot, frameCounter + 1, false)) {
            mask[slot / 32] |= 1u << uint(slot % 32);
        }
    }
    int word = int(gl_FragCoord.x) - worldRegion(WORLD_REGION_LIGHT_SELECTION).x - 6;
    result = worldEncodeUint(mask[word]);
}
