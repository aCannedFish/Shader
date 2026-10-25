/* Palette inputs are live resource PNGs, bound only during prepare. No host
 * pixels or mineral masks are generated or uploaded by a companion or helper.
 */
#ifndef SIMPLE_WORLD_ORE_SOURCES_GLSL
#define SIMPLE_WORLD_ORE_SOURCES_GLSL
uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D worldTextureAtlas;

ivec2 worldOreHostSize(int host) {
    if (host == 0) return textureSize(colortex0, 0);
    if (host == 1) return textureSize(colortex1, 0);
    return textureSize(colortex2, 0);
}

uvec4 worldOreHostPixel(int host, ivec2 pixel) {
    vec4 value;
    if (host == 0) value = texelFetch(colortex0, pixel, 0);
    else if (host == 1) value = texelFetch(colortex1, pixel, 0);
    else value = texelFetch(colortex2, pixel, 0);
    return uvec4(round(clamp(value, 0.0, 1.0) * 255.0));
}

uint worldOreHash(uint hash, uvec4 value) {
    uint packedValue = value.r | (value.g << 8u) | (value.b << 16u) | (value.a << 24u);
    return (hash ^ packedValue) * 16777619u;
}
#endif
