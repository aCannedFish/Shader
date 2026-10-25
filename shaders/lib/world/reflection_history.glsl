/* Water reflection history is independent of display colour and air fog.
 * Finite-word storage preserves HDR, receiver depth and identity in one target.
 * Every read decodes first; packed values must never use hardware interpolation.
 */
#ifndef SIMPLE_WORLD_REFLECTION_HISTORY_GLSL
#define SIMPLE_WORLD_REFLECTION_HISTORY_GLSL
#include "/lib/world/water_packet.glsl"
#include "/lib/water.glsl"

struct WorldReflectionHistory {
    vec3 radiance;
    vec3 normal;
    float depth;
    float confidence;
    int frame;
    int count;
    bool valid;
};

WorldReflectionHistory worldEmptyReflection() {
    return WorldReflectionHistory(vec3(0.0), vec3(0.0, 1.0, 0.0), 0.0, 0.0, -1, 0, false);
}

vec4 worldPackReflection(WorldReflectionHistory value) {
    if (!value.valid) return vec4(0.0);
    uvec4 words = uvec4(0u);
    uvec2 normal = uvec2(round(encodeWaterNormal(value.normal) * 4095.0));
    worldPutRawField(words, waterRgb9e5(value.radiance), 0, 32);
    worldPutRawField(words, normal.x, 32, 12);
    worldPutRawField(words, normal.y, 44, 12);
    worldPutRawField(words, floatBitsToUint(value.depth), 56, 32);
    worldPutRawField(words, uint(value.frame), 88, 20);
    worldPutRawField(words, uint(value.count), 108, 5);
    worldPutRawField(words, uint(round(clamp(value.confidence, 0.0, 1.0) * 15.0)), 113, 4);
    worldPutRawField(words, 5u, 117, 3);
    return worldRawEncode(words, true, false);
}

WorldReflectionHistory worldUnpackReflection(vec4 packedValue) {
    WorldReflectionHistory result = worldEmptyReflection();
    if (!worldRawValid(packedValue)) return result;
    uvec4 words = worldRawDecode(packedValue);
    if (worldGetRawField(words, 117, 3) != 5u) return result;
    result.radiance = waterRgb9e5Value(worldGetRawField(words, 0, 32));
    result.normal = decodeWaterNormal(vec2(worldGetRawField(words, 32, 12),
        worldGetRawField(words, 44, 12)) / 4095.0);
    result.depth = uintBitsToFloat(worldGetRawField(words, 56, 32));
    result.frame = int(worldGetRawField(words, 88, 20));
    result.count = int(worldGetRawField(words, 108, 5));
    result.confidence = float(worldGetRawField(words, 113, 4)) / 15.0;
    result.valid = result.depth > 0.0;
    return result;
}

WorldReflectionHistory worldReflectionHistoryAt(ivec2 pixel) {
    ivec2 size = textureSize(colortex7, 0);
    return worldUnpackReflection(texelFetch(colortex7, clamp(pixel, ivec2(0), size - 1), 0));
}

// Reconstruct only samples on this water plane, with compatible wave normals.
// Thin water/shore contacts that have no valid neighbours use a full query.
vec4 worldWaterReflectionAt(vec2 uv, vec3 position, vec3 normal) {
    ivec2 size = textureSize(colortex7, 0);
    vec2 coordinate = uv * vec2(size) - 0.5;
    ivec2 first = ivec2(floor(coordinate));
    vec2 fraction = fract(coordinate);
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
    float height = viewToWorld(position).y;
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            ivec2 pixel = clamp(first + ivec2(x, y), ivec2(0), size - 1);
            WorldReflectionHistory value = worldReflectionHistoryAt(pixel);
            if (!value.valid || value.frame != frameCounter) continue;
            vec2 sampleUv = (vec2(pixel) + 0.5) / vec2(size);
            vec3 point = waterSurfacePosition(sampleUv, value.depth);
            float heightError = abs(viewToWorld(point).y - height);
            float agreement = dot(normalWorld, value.normal);
            if (heightError > 0.08 || agreement < 0.94) continue;
            float spatial = (x == 0 ? 1.0 - fraction.x : fraction.x)
                * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = spatial * exp(-heightError * 20.0) * pow(agreement, 24.0);
            sum += value.radiance * weight;
            total += weight;
        }
    }
    return total > 0.05 ? vec4(sum / total, 1.0) : vec4(0.0);
}
#endif
