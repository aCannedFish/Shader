/* Active-resource mineral masks, packed as exact byte values in RGBA16F.
 * Sampling at texel centres avoids interpolation between packed bits. Without
 * the current companion masks the effect is off, preserving the rock surface.
 */
#ifndef LIB_ORE_EMISSION_GLSL
#define LIB_ORE_EMISSION_GLSL
#include "../settings.glsl"
#include "common.glsl"
#include "color_space.glsl"
#include "companion_lighting.glsl"

vec4 oreMaskTexel(float index) {
    vec2 size = companionAtlasSize();
    vec2 pixel = vec2(mod(index, size.x), 8.0 + floor(index / size.x));
    return texture2D(companionAtlas, (pixel + 0.5) / size);
}

float oreMaskBit(float ore, vec2 pixel, float start) {
    pixel = clamp(pixel, vec2(0.0), vec2(63.0));
    float index = pixel.y * 64.0 + pixel.x;
    vec4 bytes = oreMaskTexel(start + ore * 128.0 + floor(index / 32.0));
    float channel = floor(mod(index, 32.0) / 8.0);
    float value = channel < 0.5 ? bytes.r : channel < 1.5 ? bytes.g : channel < 2.5 ? bytes.b : bytes.a;
    return mod(floor(value / exp2(mod(index, 8.0))), 2.0);
}

vec3 oreEmission(float blockId, vec2 atlasUv, vec3 textureColour) {
    if (ORE_GLOW_STRENGTH <= 0.0 || blockId < 399.5 || blockId > 417.5 || !hasCompanionLighting()) {
        return vec3(0.0);
    }
    vec4 header = oreMaskTexel(0.0);
    if (abs(header.r - 3142.0) > 0.5 || abs(header.g - 64.0) > 0.5) {
        return vec3(0.0);
    }
    float ore = floor(blockId - 400.0 + 0.5);
    vec4 bounds = oreMaskTexel(2.0 + ore * 2.0);
    vec2 residual = oreMaskTexel(3.0 + ore * 2.0).rg;
    if (min(bounds.z, bounds.w) <= 0.0) {
        return vec3(0.0);
    }
    vec2 uv = (atlasUv - bounds.xy - residual) / bounds.zw;
    if (min(uv.x, uv.y) < -0.001 || max(uv.x, uv.y) > 1.001) {
        return vec3(0.0);
    }
    // Nearest masks retain the original pixel-art boundary. A filtered mask
    // would leak emission from a mineral pixel into the surrounding stone.
    float mask = oreMaskBit(ore, floor(clamp(uv, 0.0, 0.99999) * 64.0), header.a);
    vec3 pigment = toLinearSpace(textureColour);
    pigment /= max(max(pigment.r, max(pigment.g, pigment.b)), 0.035);
    float strength = ore < 1.5 ? 0.0 : ore < 5.5 ? 0.55 : 0.85;
    return pigment * mask * strength * ORE_GLOW_STRENGTH;
}
#endif
