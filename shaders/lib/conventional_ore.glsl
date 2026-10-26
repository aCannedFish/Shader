/* Standalone mineral emission for vanilla-style ore textures. Color contrast
 * separates mineral pixels from neutral stone, and pale quartz from netherrack.
 * Coal stays unlit. This replaces the companion's atlas masks with a bounded
 * approximation; resource packs with differently colored hosts may need tuning.
 */
#ifndef SIMPLE_CONVENTIONAL_ORE_GLSL
#define SIMPLE_CONVENTIONAL_ORE_GLSL
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color_space.glsl"

vec3 oreEmission(float blockId, vec2 atlasUv, vec3 textureColour) {
    int ore = int(floor(blockId + 0.5)) - 400;
    if (ORE_GLOW_STRENGTH <= 0.0 || ore < 2 || ore > 17) {
        return vec3(0.0);
    }
    vec3 color = clamp(textureColour, vec3(0.0), vec3(1.0));
    float mask;
    if (ore <= 3) {
        mask = smoothstep(0.04, 0.11, color.r - color.b);
    } else if (ore <= 5) {
        float contrast = max(color.r, max(color.g, color.b))
            - min(color.r, min(color.g, color.b));
        mask = smoothstep(0.06, 0.15, contrast);
    } else if (ore <= 7 || ore == 16) {
        mask = smoothstep(0.08, 0.18, min(color.r, color.g) - color.b);
    } else if (ore <= 9) {
        mask = smoothstep(0.08, 0.18, color.r - max(color.g, color.b));
    } else if (ore <= 11) {
        mask = smoothstep(0.08, 0.18, color.b - color.r);
    } else if (ore <= 13) {
        mask = smoothstep(0.08, 0.18, color.g - max(color.r, color.b));
    } else if (ore <= 15) {
        mask = smoothstep(0.06, 0.16, min(color.g, color.b) - color.r);
    } else {
        float contrast = max(color.r, max(color.g, color.b))
            - min(color.r, min(color.g, color.b));
        mask = smoothstep(0.30, 0.55, min(color.g, color.b))
            * (1.0 - smoothstep(0.15, 0.35, contrast));
    }
    vec3 pigment = toLinearSpace(color);
    pigment /= max(max(pigment.r, max(pigment.g, pigment.b)), 0.035);
    float strength = ore <= 5 ? 0.55 : 0.85;
    return pigment * mask * strength * ORE_GLOW_STRENGTH;
}
#endif
