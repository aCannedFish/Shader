#ifndef SIMPLE_WORLD_DYNAMIC_IDENTITY_GLSL
#define SIMPLE_WORLD_DYNAMIC_IDENTITY_GLSL
#include "/lib/world/coordinates.glsl"
#include "/lib/world/layout.glsl"
#include "/lib/world/dynamic_layout.glsl"

// J9 may leave blockEntityId from a previous batched model-part draw. Native
// conduit faces retain their actual atlas UVs, so match the complete face image
// and its physical size against live resource textures rather than that ID.
// Two independent byte hashes cover every texel; dimensions are checked apart.
bool worldDynamicFaceHash(sampler2D image, ivec2 first, ivec2 size, out uvec2 hash) {
    hash = uvec2(2166136261u, 5381u);
    if (any(lessThan(size, ivec2(1))) || any(greaterThan(size, ivec2(64)))
        || any(lessThan(first, ivec2(0)))
        || any(greaterThan(first + size, textureSize(image, 0)))) return false;
    for (int index = 0; index < 4096; index++) {
        if (index >= size.x * size.y) break;
        uvec4 pixel = uvec4(round(clamp(texelFetch(image,
            first + ivec2(index % size.x, index / size.x), 0), 0.0, 1.0) * 255.0));
        // Atlas stitching may dilate colour into zero-alpha texels. Those
        // hidden RGB bytes are unrelated to material identity or coverage.
        if (pixel.w == 0u) pixel.xyz = uvec3(0u);
        uint rgba = pixel.x | (pixel.y << 8u) | (pixel.z << 16u) | (pixel.w << 24u);
        hash.x = (hash.x ^ rgba) * 16777619u;
        hash.y = ((hash.y << 5u) + hash.y) ^ rgba;
    }
    return true;
}

// Only native square cube faces qualify. This rejects chest bases, text,
// beams and particle quads before any image reads. Missing matches stay with
// the ordinary semantic path; they never fabricate a new emitter identity.
int worldDynamicMaterial(sampler2D data, sampler2D image,
    vec3 a, vec3 b, vec3 c, vec2 ua, vec2 ub, vec2 uc) {
    vec3 edge = vec3(dot(b - a, b - a), dot(c - b, c - b), dot(c - a, c - a));
    float side = min(edge.x, min(edge.y, edge.z));
    float diagonal = max(edge.x, max(edge.y, edge.z));
    float otherSide = edge.x + edge.y + edge.z - side - diagonal;
    int model = abs(side - 0.140625) < 0.00002 ? 0
        : abs(side - 0.25) < 0.00002 ? 1 : -1;
    if (model < 0 || abs(diagonal - 2.0 * side) > side * 0.001
        || abs(otherSide - side) > side * 0.001) return 0;
    ivec2 extent = textureSize(image, 0);
    ivec2 first = ivec2(round(min(ua, min(ub, uc)) * vec2(extent)));
    ivec2 size = ivec2(round(max(ua, max(ub, uc)) * vec2(extent))) - first;
    uvec2 hash;
    if (!worldDynamicFaceHash(image, first, size, hash)) return 0;
    ivec2 base = worldRegion(WORLD_REGION_DYNAMIC_SPRITES).xy;
    for (int face = 0; face < 6; face++) {
        ivec2 address = base + ivec2((model * 6 + face) * 3, 0);
        vec4 metadata = texelFetch(data, address + ivec2(2, 0), 0);
        if (metadata.w != 1647.0 || any(notEqual(ivec2(round(metadata.xy)), size))) continue;
        uvec2 reference = uvec2(worldDecodeUint(texelFetch(data, address, 0)),
            worldDecodeUint(texelFetch(data, address + ivec2(1, 0), 0)));
        if (all(equal(hash, reference))) return WORLD_CONDUIT_MATERIAL;
    }
    return 0;
}
#endif
