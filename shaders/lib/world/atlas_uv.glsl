#ifndef SIMPLE_WORLD_ATLAS_UV_GLSL
#define SIMPLE_WORLD_ATLAS_UV_GLSL

// J9's anisotropic multi-texture path binds individual sprite textures and
// supplies local UVs. Other paths supply atlas UVs and leave bounds undefined.
vec2 worldAtlasUv(vec2 uv, vec4 bounds, ivec2 boundSize, ivec2 atlasSize) {
    vec2 extent = bounds.zw - bounds.xy;
    bool sprite = all(greaterThan(extent, vec2(0.0)))
        && all(lessThanEqual(bounds.zw, vec2(1.0)))
        && all(greaterThanEqual(bounds.xy, vec2(0.0)))
        && all(greaterThanEqual(atlasSize, boundSize))
        && any(greaterThan(atlasSize, boundSize));
    return sprite ? bounds.xy + uv * extent : uv;
}
#endif
