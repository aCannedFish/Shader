#include "/lib/world/light_selection.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
uniform vec3 cameraPosition;
uniform int frameCounter;
layout(location=0) out vec4 result;

// The paired invocation updates both banks. Only this level's rectangle is
// rasterized, so building the tree does not copy the complete world atlas.
void main() {
    ivec2 local = ivec2(gl_FragCoord.xy) - WORLD_LIGHT_DRAW_RECT.xy;
    int index = local.x + local.y * WORLD_LIGHT_DRAW_RECT.z;
    result = vec4(0.0);
    if (index >= worldLightLevelCount(WORLD_LIGHT_BUILD_LEVEL)) return;
    vec4 best = vec4(0.0);
    for (int child = 0; child < 4; child++) {
        vec4 candidate = worldLightNode(colortex6, WORLD_LIGHT_BUILD_LEVEL - 1,
            index * 4 + child, cameraPosition, frameCounter);
        if (candidate.w > 0.0 && (best.w <= 0.0 || worldLightBetter(candidate, best))) best = candidate;
    }
    uint id = uint(round(best.z));
    result = vec4(id & 255u, (id >> 8u) & 255u, (id >> 16u) & 255u, best.w);
}
