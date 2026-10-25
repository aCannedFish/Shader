/* Water geometry and radiance share one RGBA32F attachment. RGB carries three
 * finite 30-bit words; A remains a normal 0/1 blend mask so glass preserves it.
 * Layout: 12+12 normal bits, 32 depth bits, RGB9E5 radiance and a two-bit tag.
 */
#ifndef SIMPLE_WORLD_WATER_PACKET_GLSL
#define SIMPLE_WORLD_WATER_PACKET_GLSL
#include "/lib/world/raw_packing.glsl"

struct WaterSurfacePacket {
    vec2 normal;
    float depth;
    vec3 scattering;
    float coverage;
};

uint waterRgb9e5(vec3 radiance) {
    vec3 colour = clamp(radiance, vec3(0.0), vec3(65408.0));
    float peak = max(colour.r, max(colour.g, colour.b));
    int exponent = clamp(int(floor(log2(max(peak, 1e-16)))) + 16, 0, 31);
    float unit = exp2(float(exponent - 24));
    uvec3 mantissa = uvec3(floor(colour / unit + 0.5));
    if (max(mantissa.r, max(mantissa.g, mantissa.b)) > 511u && exponent < 31) {
        exponent++;
        unit *= 2.0;
        mantissa = uvec3(floor(colour / unit + 0.5));
    }
    mantissa = min(mantissa, uvec3(511u));
    return mantissa.r | (mantissa.g << 9u) | (mantissa.b << 18u) | (uint(exponent) << 27u);
}

vec3 waterRgb9e5Value(uint value) {
    uvec3 mantissa = uvec3(value, value >> 9u, value >> 18u) & uvec3(511u);
    return vec3(mantissa) * exp2(float(int(value >> 27u) - 24));
}

vec4 packWaterSurface(vec2 normal, float depth, vec3 scattering) {
    uvec4 words = uvec4(0u);
    uvec2 encoded = uvec2(round(clamp(normal, 0.0, 1.0) * 4095.0));
    worldPutRawField(words, encoded.x, 0, 12);
    worldPutRawField(words, encoded.y, 12, 12);
    worldPutRawField(words, floatBitsToUint(depth), 24, 32);
    worldPutRawField(words, waterRgb9e5(scattering), 56, 32);
    worldPutRawField(words, 2u, 88, 2);
    return vec4(worldRawFloat(words.x), worldRawFloat(words.y), worldRawFloat(words.z), 1.0);
}

WaterSurfacePacket unpackWaterSurface(vec4 packedValue) {
    WaterSurfacePacket result = WaterSurfacePacket(vec2(0.5), 0.0, vec3(0.0), 0.0);
    if (packedValue.a < 0.5) return result;
    uvec4 words = uvec4(worldRawUint(packedValue.x), worldRawUint(packedValue.y),
        worldRawUint(packedValue.z), 0u);
    if (worldGetRawField(words, 88, 2) != 2u) return result;
    result.normal = vec2(worldGetRawField(words, 0, 12), worldGetRawField(words, 12, 12)) / 4095.0;
    result.depth = uintBitsToFloat(worldGetRawField(words, 24, 32));
    result.scattering = waterRgb9e5Value(worldGetRawField(words, 56, 32));
    result.coverage = 1.0;
    return result;
}

WaterSurfacePacket readWaterPacket(sampler2D geometry, vec2 uv) {
    ivec2 size = textureSize(geometry, 0);
    vec2 coordinate = uv * vec2(size) - 0.5;
    ivec2 nearest = clamp(ivec2(floor(uv * vec2(size))), ivec2(0), size - 1);
    if (all(lessThan(abs(coordinate - round(coordinate)), vec2(0.0002)))) {
        return unpackWaterSurface(texelFetch(geometry, nearest, 0));
    }
    ivec2 first = ivec2(floor(coordinate));
    vec2 fraction = fract(coordinate);
    WaterSurfacePacket sum = WaterSurfacePacket(vec2(0.0), 0.0, vec3(0.0), 0.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            ivec2 pixel = clamp(first + ivec2(x, y), ivec2(0), size - 1);
            WaterSurfacePacket value = unpackWaterSurface(texelFetch(geometry, pixel, 0));
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                * (y == 0 ? 1.0 - fraction.y : fraction.y) * value.coverage;
            sum.normal += value.normal * weight;
            sum.depth += value.depth * weight;
            sum.scattering += value.scattering * weight;
            sum.coverage += weight;
        }
    }
    if (sum.coverage < 0.5) return WaterSurfacePacket(vec2(0.5), 0.0, vec3(0.0), 0.0);
    sum.normal /= sum.coverage;
    sum.depth /= sum.coverage;
    sum.scattering /= sum.coverage;
    return sum;
}
#endif
