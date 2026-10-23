#ifndef SIMPLE_WORLD_RAW_UV_GLSL
#define SIMPLE_WORLD_RAW_UV_GLSL
#include "/lib/world/raw_packing.glsl"
#include "/lib/world/uv.glsl"

// Six 20-bit coefficients occupy one finite RGBA32F record. This leaves the
// other shadow attachment available for independent model-choice accumulation.
vec4 worldRawEncodeUv(WorldUv mapping) {
    if (!mapping.valid) return vec4(0.0);
    uint a = worldUvScalarBits(mapping.u.x);
    uint b = worldUvScalarBits(mapping.u.y);
    uint c = worldUvScalarBits(mapping.u.z);
    uint d = worldUvScalarBits(mapping.v.x);
    uint e = worldUvScalarBits(mapping.v.y);
    uint f = worldUvScalarBits(mapping.v.z);
    uvec4 words = uvec4(a | ((b & 1023u) << 20u), (b >> 10u) | (c << 10u),
        d | ((e & 1023u) << 20u), (e >> 10u) | (f << 10u));
    return worldRawEncode(words, mapping.valid, mapping.tinted);
}

WorldUv worldRawDecodeUv(vec4 record) {
    if (!worldRawValid(record)) return WorldUv(vec3(0.0), vec3(0.0), false, false);
    uvec4 words = worldRawDecode(record);
    uint a = words.x & 1048575u;
    uint b = (words.x >> 20u) | ((words.y & 1023u) << 10u);
    uint c = words.y >> 10u;
    uint d = words.z & 1048575u;
    uint e = (words.z >> 20u) | ((words.w & 1023u) << 10u);
    uint f = words.w >> 10u;
    return WorldUv(vec3(worldUvScalarValue(a), worldUvScalarValue(b), worldUvScalarValue(c)),
        vec3(worldUvScalarValue(d), worldUvScalarValue(e), worldUvScalarValue(f)), true, record.x < 0.0);
}
#endif
