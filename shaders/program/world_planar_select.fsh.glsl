/* Select the water plane with the largest current projected area. The raw
 * histogram comes from real water triangles, independent of camera depth.
 */
#include "/lib/world/planar.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
uniform sampler2D shadowcolor0;
uniform int frameCounter;
layout(location=0) out vec4 result;

void main() {
    int word = int(gl_FragCoord.x) - worldRegion(WORLD_REGION_PLANAR_CONTROL).x;
    result = vec4(0.0);
    if (word < 4) {
        result = worldPlanarWord(colortex6, word, true);
        return;
    }
    int nextWord = word - 4;
    float strongest = 0.0;
    float height = 0.0;
    for (int index = 0; index < 384; index++) {
        vec4 candidate = texelFetch(shadowcolor0, WORLD_CAPTURE_WATER_PLANES.xy + ivec2(index, 0), 0);
        if (candidate.y > strongest) {
            strongest = candidate.y;
            height = candidate.x / candidate.y;
        }
    }
    if (nextWord == 0) result = vec4(1149.0, strongest > 0.000001 ? 1.0 : 0.0, 0.0, 0.0);
    if (nextWord == 1) result = worldEncodeUint(floatBitsToUint(height));
    if (nextWord == 2) result = worldEncodeInt(frameCounter);
    if (nextWord == 3) result = worldEncodeUint(worldReadGeneration(colortex6));
}
