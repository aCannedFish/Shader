#ifndef SIMPLE_WORLD_RAW_OBSERVATION_GLSL
#define SIMPLE_WORLD_RAW_OBSERVATION_GLSL
#include "/lib/world/raw_packing.glsl"

struct WorldObservation {
    int material;
    int face;
    int light;
    ivec3 offsetCode;
    bool offsetValid;
    bool tintValid;
    vec3 tint;
    vec3 albedo;
};

// GLSL 3.30 has no packHalf2x16. Preserve the prior half-float albedo precision,
// including subnormals and round-to-nearest-even, without requiring GL 4.2.
uint worldPositiveHalf(float value) {
    uint bits = floatBitsToUint(clamp(value, 0.0, 65504.0));
    int exponent = int((bits >> 23u) & 255u) - 112;
    uint mantissa = bits & 0x007fffffu;
    if (exponent <= 0) {
        int shift = 14 - exponent;
        if (shift > 24) return 0u;
        uint significant = mantissa | 0x00800000u;
        uint truncated = significant >> uint(shift);
        uint tail = significant & ((1u << uint(shift)) - 1u);
        uint halfway = 1u << uint(shift - 1);
        return truncated + uint(tail > halfway || (tail == halfway && (truncated & 1u) != 0u));
    }
    uint result = (uint(exponent) << 10u) | (mantissa >> 13u);
    uint tail = mantissa & 8191u;
    result += uint(tail > 4096u || (tail == 4096u && (result & 1u) != 0u));
    return min(result, 0x7bffu);
}

float worldPositiveHalfValue(uint bits) {
    uint exponent = bits >> 10u;
    uint mantissa = bits & 1023u;
    if (exponent == 0u) return float(mantissa) / 16777216.0;
    return uintBitsToFloat(((exponent + 112u) << 23u) | (mantissa << 13u));
}

WorldObservation worldUnknownObservation() {
    return WorldObservation(0, 0, 0, ivec3(0), false, false, vec3(0.0), vec3(0.0));
}

// Fields occupy 120 bits: material 15, face 3, light 8, offset validity 1,
// tint validity 1, offset indices 12, tint 24, three half colours 48, and an 8-bit signature.
vec4 worldEncodeObservation(WorldObservation value) {
    if (value.material <= 0 || value.material >= 32768 || value.face < 0 || value.face >= 6
        || value.light < 0 || value.light > 255 || any(lessThan(value.offsetCode, ivec3(0)))
        || any(greaterThan(value.offsetCode, ivec3(15))) || any(isnan(value.albedo))
        || any(isinf(value.albedo)) || any(isnan(value.tint)) || any(isinf(value.tint))) return vec4(0.0);
    uvec4 words = uvec4(0u);
    uvec3 tint = uvec3(round(clamp(value.tint, vec3(0.0), vec3(1.0)) * 255.0));
    uint offset = uint(value.offsetCode.x) | (uint(value.offsetCode.y) << 4u)
        | (uint(value.offsetCode.z) << 8u);
    worldPutRawField(words, uint(value.material), 0, 15);
    worldPutRawField(words, uint(value.face), 15, 3);
    worldPutRawField(words, uint(value.light), 18, 8);
    worldPutRawField(words, uint(value.offsetValid), 26, 1);
    worldPutRawField(words, uint(value.tintValid), 27, 1);
    worldPutRawField(words, offset, 28, 12);
    worldPutRawField(words, tint.x | (tint.y << 8u) | (tint.z << 16u), 40, 24);
    worldPutRawField(words, worldPositiveHalf(value.albedo.r), 64, 16);
    worldPutRawField(words, worldPositiveHalf(value.albedo.g), 80, 16);
    worldPutRawField(words, worldPositiveHalf(value.albedo.b), 96, 16);
    worldPutRawField(words, 167u, 112, 8);
    return worldRawEncode(words, true, false);
}

WorldObservation worldDecodeObservation(vec4 record) {
    if (!worldRawValid(record) || record.x < 0.0) return worldUnknownObservation();
    uvec4 words = worldRawDecode(record);
    if (worldGetRawField(words, 112, 8) != 167u) return worldUnknownObservation();
    int material = int(worldGetRawField(words, 0, 15));
    int face = int(worldGetRawField(words, 15, 3));
    uvec3 halfColour = uvec3(worldGetRawField(words, 64, 16),
        worldGetRawField(words, 80, 16), worldGetRawField(words, 96, 16));
    if (material == 0 || face >= 6 || any(greaterThan(halfColour, uvec3(0x7bffu)))) {
        return worldUnknownObservation();
    }
    uint offset = worldGetRawField(words, 28, 12);
    uint tint = worldGetRawField(words, 40, 24);
    return WorldObservation(material, face, int(worldGetRawField(words, 18, 8)),
        ivec3(offset & 15u, (offset >> 4u) & 15u, (offset >> 8u) & 15u),
        worldGetRawField(words, 26, 1) != 0u,
        worldGetRawField(words, 27, 1) != 0u,
        vec3(tint & 255u, (tint >> 8u) & 255u, (tint >> 16u) & 255u) / 255.0,
        vec3(worldPositiveHalfValue(halfColour.r), worldPositiveHalfValue(halfColour.g),
            worldPositiveHalfValue(halfColour.b)));
}
#endif
