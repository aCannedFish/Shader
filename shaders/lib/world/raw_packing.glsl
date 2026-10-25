#ifndef SIMPLE_WORLD_RAW_PACKING_GLSL
#define SIMPLE_WORLD_RAW_PACKING_GLSL

// Each word carries 30 bits in a normalized finite float. Exponents 1..128
// avoid NaNs, infinities and subnormals; RGBA32F stores every bit unchanged.
float worldRawFloat(uint value) {
    uint mantissa = value & 0x007fffffu;
    uint exponent = ((value >> 23u) + 1u) << 23u;
    return uintBitsToFloat(exponent | mantissa);
}

uint worldRawUint(float value) {
    uint word = floatBitsToUint(abs(value));
    uint exponent = ((word >> 23u) & 255u) - 1u;
    return (exponent << 23u) | (word & 0x007fffffu);
}

vec4 worldRawEncode(uvec4 words, bool valid, bool tagged) {
    if (!valid) return vec4(0.0);
    vec4 result = vec4(worldRawFloat(words.x), worldRawFloat(words.y),
        worldRawFloat(words.z), -worldRawFloat(words.w));
    if (tagged) result.x = -result.x;
    return result;
}

bool worldRawValid(vec4 record) {
    if (record.w >= 0.0) return false;
    uvec4 words = floatBitsToUint(abs(record));
    uvec4 exponents = (words >> 23u) & uvec4(255u);
    return all(greaterThanEqual(exponents, uvec4(1u)))
        && all(lessThanEqual(exponents, uvec4(128u)));
}

uvec4 worldRawDecode(vec4 record) {
    return uvec4(worldRawUint(record.x), worldRawUint(record.y),
        worldRawUint(record.z), worldRawUint(record.w));
}
// Read/write fields across the 30-bit word boundary, including full floats.
void worldPutRawField(inout uvec4 words, uint value, int first, int bits) {
    int word = first / 30;
    int shift = first % 30;
    value &= bits == 32 ? 0xffffffffu : (1u << uint(bits)) - 1u;
    words[word] |= (value << uint(shift)) & 0x3fffffffu;
    if (shift + bits > 30) words[word + 1] |= value >> uint(30 - shift);
}

uint worldGetRawField(uvec4 words, int first, int bits) {
    int word = first / 30;
    int shift = first % 30;
    uint value = words[word] >> uint(shift);
    if (shift + bits > 30) value |= words[word + 1] << uint(30 - shift);
    return value & (bits == 32 ? 0xffffffffu : (1u << uint(bits)) - 1u);
}


#endif
