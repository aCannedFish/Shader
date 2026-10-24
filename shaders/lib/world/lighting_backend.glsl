/* GPU replacements for the surface-lighting API during migration. Native light
 * levels retain the calibrated energy; the world atlas supplies emitter hue,
 * independent point visibility, glass transfer and published diffuse SH.
 */
#ifndef SIMPLE_WORLD_LIGHTING_BACKEND_GLSL
#define SIMPLE_WORLD_LIGHTING_BACKEND_GLSL
#include "/settings.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/common.glsl"
#include "/lib/lightmap.glsl"
#include "/lib/world/hue.glsl"
#include "/lib/world/point_shadow.glsl"
#include "/lib/world/glass_cache.glsl"
#include "/lib/world/gi.glsl"

#include "/lib/world/storage.glsl"
#define companionAtlas colortex6
#define companionOrigin vec3(worldReadOrigin(colortex6, false))
#define companionHueOrigin companionOrigin

bool hasCompanionLighting() {
    return worldDecodeUint(texelFetch(colortex6, worldRegion(WORLD_REGION_HEADER).xy, 0))
        == WORLD_LAYOUT_SIGNATURE;
}

vec2 companionAtlasSize() {
    return vec2(textureSize(colortex6, 0));
}

vec4 companionHeader() {
    return vec4(2026.0, WORLD_POINT_LIGHT_COUNT, WORLD_GI_SIZE,
        worldGiState(colortex6).ready ? 1.0 : 0.0);
}

vec3 companionPosition(vec3 position, vec3 origin) {
    return (gbufferModelViewInverse * vec4(position, 1.0)).xyz + cameraPosition - origin;
}

float companionVolumeWeight(vec3 position, float size, float margin) {
    vec3 border = min(position, vec3(size) - position);
    return smoothstep(0.0, margin, min(border.x, min(border.y, border.z)));
}

vec4 companionLight(int slot, int row) {
    WorldPointLight light = worldReadPointLight(colortex6, slot);
    if (!light.valid) return vec4(0.0);
    if (row == 0) {
        float radius = worldShadowLightMapped(colortex6, slot, false) ? light.radius : -light.radius;
        return vec4(vec3(light.position.block - worldReadOrigin(colortex6, false)), radius);
    }
    if (row == 1) return vec4(light.emission * (2.0 * light.level / 15.0), light.level);
    return vec4(light.position.fraction, 1.0);
}

vec3 companionTransmission(int slot, vec3 position) {
    return worldPointGlassFilter(colortex6, slot,
        worldPosition(position + companionOrigin, vec3(0.0)), vec3(0.0));
}

vec3 companionShadow(int slot, vec3 ray, float radius, vec3 normal, vec3 transfer) {
#if ENABLE_LOCAL_SHADOWS == 0
    return transfer;
#else
    float visibility = worldPointShadowVisibility(colortex6, slot, ray, radius, normal);
    return transfer * mix(1.0, visibility, LOCAL_SHADOW_STRENGTH);
#endif
}

vec4 companionHue(vec3 position) {
    return worldHue(colortex6, worldPosition(position + companionOrigin, vec3(0.0)));
}

// Preserve the native maximum-light model: a blocked source removes only the
// share it explains beyond the strongest still-visible source at the receiver.
vec3 worldSurfaceVisibility(WorldPosition receiver, vec3 normal, float level) {
    vec3 cell = floor(receiver.fraction + normal * 0.5) + 0.5;
    vec3 visible = vec3(0.0);
    float explained = 0.0;
    float observed = blockLightAttenuation(level / 15.0);
    for (int slot = 0; slot < WORLD_POINT_LIGHT_COUNT; slot++) {
        WorldPointLight light = worldReadPointLight(colortex6, slot);
        if (!light.valid) continue;
        vec3 delta = abs(vec3(light.position.block - receiver.block) + vec3(0.5) - cell);
        float expected = light.level - delta.x - delta.y - delta.z;
        if (expected <= 0.0) continue;
        float weight = blockLightAttenuation(min(expected, level) / 15.0)
            * (1.0 - smoothstep(5.0, 9.0, expected - level));
        explained = max(explained, weight);
        if (weight <= min(visible.r, min(visible.g, visible.b))) continue;
        vec3 ray = vec3(light.position.block - receiver.block)
            + light.position.fraction - receiver.fraction;
        float squared = dot(ray, ray);
        vec3 visibility = vec3(1.0);
        if (squared > 0.0001 && squared < light.radius * light.radius) {
            float wrap = clamp(1.0 + 2.0 * dot(normal, ray) * inversesqrt(squared), 0.0, 1.0);
            vec3 transfer = wrap > 0.0
                ? worldPointGlassFilter(colortex6, slot, receiver, normal) : vec3(1.0);
            visibility = companionShadow(slot, -ray, light.radius, normal, transfer) * wrap;
        }
        visible = max(visible, visibility * weight);
    }
    return explained > 0.0
        ? clamp(1.0 - (explained - visible) / max(observed, explained), 0.0, 1.0) : vec3(1.0);
}

vec3 companionBlockLight(vec3 position, vec3 normalView, vec2 lmCoord, vec3 nativeRadiance) {
    if (nativeRadiance.r <= 0.000001 || !hasCompanionLighting()) return nativeRadiance;
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    WorldPosition receiver = worldPosition((gbufferModelViewInverse * vec4(position, 1.0)).xyz, cameraPosition);
    vec3 colour = nativeRadiance / nativeRadiance.r;
    float energy = nativeRadiance.r;
    float level = lightmapLevel(lmCoord.x) * 15.0;
#if ENABLE_COLOURED_LIGHTING == 1
    WorldPosition outside = worldPosition(receiver.fraction + normal * 0.5, vec3(receiver.block));
    vec4 hue = worldHue(colortex6, outside);
    ivec3 cell = outside.block - worldReadOrigin(colortex6, false);
    vec3 border = min(vec3(cell), vec3(WORLD_FAR_SHAPE - cell));
    float coverage = step(0.5, hue.a) * smoothstep(0.0, 4.0, min(border.x, min(border.y, border.z)));
    colour = mix(colour, hue.rgb, coverage);
    float ownLevel = level;
#if SMOOTH_BLOCK_LIGHT == 0
    ownLevel = floor(ownLevel + 0.5);
#endif
    float own = 4.0 * BLOCK_LIGHT_STRENGTH * min(hue.a, 15.0) / 15.0
        * emitterLightAttenuation(ownLevel, min(hue.a, 15.0), 2.0);
    energy = mix(energy, max(energy, own), coverage);
#endif
    return colour * energy * worldSurfaceVisibility(receiver, normal, level);
}

vec3 companionIndirect(vec3 position, vec3 normalView) {
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    WorldPosition receiver = worldPosition((gbufferModelViewInverse * vec4(position, 1.0)).xyz, cameraPosition);
    return worldIndirectLight(colortex6, receiver, normal);
}
#endif
