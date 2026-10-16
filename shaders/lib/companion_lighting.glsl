/*
 * Companion-provided light positions, independent cube-face shadows and diffuse
 * radiance volumes. All data remains linear HDR. Missing companion data selects
 * the existing Minecraft light-field fallback through companionReady = 0.
 * Block-light energy and wall occlusion always come from the native light field;
 * the companion supplies emitter hue (hue volume) and point-light visibility.
 */
#ifndef LIB_COMPANION_LIGHTING_GLSL
#define LIB_COMPANION_LIGHTING_GLSL
#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"
#include "lightmap.glsl"

uniform sampler2D companionAtlas;
uniform sampler2D companionRadiance;
uniform int companionReady;
uniform vec3 companionOrigin;
uniform vec3 companionGiOrigin;
uniform vec3 companionHueOrigin;
uniform vec2 companionDimensions;

// Must match HueVolume.java: 8^3 bricks over a camera-centred 256x128x256 region,
// one indirection texel per brick, then 64x8-texel bricks in a slot pool.
const vec3 COMPANION_HUE_BRICKS = vec3(32.0, 16.0, 32.0);

// These options also configure the Mod's resource and scheduling budgets.
const int companionSizeOption = GI_VOLUME_SIZE;
const int companionShadowSizeOption = LOCAL_SHADOW_RESOLUTION;
const int companionShadowUpdatesOption = LOCAL_SHADOW_UPDATES;
const int companionPropagationOption = GI_PROPAGATION_STEPS;
const int companionWorkOption = GI_WORK_PER_FRAME;
const float companionRangeOption = LOCAL_LIGHT_RADIUS;
const float companionReflectanceOption = GI_REFLECTANCE;
const float companionIntervalOption = LIGHTING_UPDATE_INTERVAL;

// Older companion versions have no explicit dimensions and retain the original layout.
vec2 companionAtlasSize() {
    if (companionDimensions.x > 0.0) {
        return companionDimensions;
    }
    return vec2(24.0 * float(LOCAL_SHADOW_RESOLUTION),
        16.0 + ceil((float(LOCAL_LIGHT_COUNT) * 6.0 + 1.0) / 24.0) * float(LOCAL_SHADOW_RESOLUTION));
}

vec4 companionMeta(float index) {
    return texture2D(companionAtlas, vec2(index + 0.5, 0.5) / companionAtlasSize());
}

vec4 companionHeader() {
    return companionMeta(0.0);
}

bool hasCompanionLighting() {
#if ENABLE_COMPANION_LIGHTING == 0
    return false;
#else
    // Layout 4 light records; an older Mod falls back to native lighting.
    return companionReady == 1 && abs(companionHeader().r - 2026.0) < 0.5 && companionMeta(2.0).x > 3.5;
#endif
}

vec3 companionPosition(vec3 viewPosition, vec3 origin) {
    // The Mod subtracts OptiFine's camera offsets from both direct and GI origins.
    return (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz + cameraPosition - origin;
}

float companionVolumeWeight(vec3 position, float size, float margin) {
    vec3 border = min(position, vec3(size) - position);
    return smoothstep(0.0, margin, min(min(border.x, border.y), border.z));
}

// The volume follows the camera in four-block steps, so anything within
// reach = size / 2 - 4 of the camera is always inside it. Fading shadows by
// camera distance before that bound avoids pops when the volume moves.
float companionCameraFade(vec3 relative, float reach) {
    vec3 distance = abs(relative);
    return 1.0 - smoothstep(reach - 4.0, reach, max(max(distance.x, distance.y), distance.z));
}

// Row 0: block cell relative to companionOrigin and signed radius (negative
// until mapped), row 1: colour and emission, row 2: in-block offset and fade.
vec4 companionLight(int index, int row) {
    return texture2D(companionAtlas, vec2(float(4 + index * 3 + row) + 0.5, 0.5) / companionAtlasSize());
}

vec2 companionShadowUv(int tile, vec2 uv) {
    float side = float(LOCAL_SHADOW_RESOLUTION);
    vec2 corner = vec2(mod(float(tile), 24.0), floor(float(tile) / 24.0)) * side;
    corner.y += 16.0;
    float inner = side - 2.0;
    vec2 bounded = clamp(uv, vec2(0.5 / inner), vec2(1.0 - 0.5 / inner));
    return (corner + 1.0 + bounded * inner) / companionAtlasSize();
}

// Two filtered slice reads reconstruct the receiver-dependent RGB transmission.
vec3 companionTransmission(int index, vec3 position) {
    vec4 cacheData = companionMeta(2.0);
    if (cacheData.x < 1.5 || cacheData.w < 0.5) {
        return vec3(1.0);
    }
    float size = companionHeader().z;
    float side = size + 2.0;
    float rows = ceil(size / 8.0);
    vec2 corner = vec2(mod(float(index), cacheData.z) * side * 8.0,
        cacheData.y + floor(float(index) / cacheData.z) * side * rows);
    vec3 p = clamp(position - 0.5, vec3(0.0), vec3(size - 1.0));
    float first = floor(p.z);
    float second = min(first + 1.0, size - 1.0);
    vec2 a = corner + vec2(mod(first, 8.0), floor(first / 8.0)) * side;
    vec2 b = corner + vec2(mod(second, 8.0), floor(second / 8.0)) * side;
    vec3 lower = texture2D(companionAtlas, (a + p.xy + 1.5) / companionAtlasSize()).rgb;
    vec3 upper = texture2D(companionAtlas, (b + p.xy + 1.5) / companionAtlasSize()).rgb;
    return clamp(mix(lower, upper, fract(p.z)), vec3(0.0), vec3(1.0));
}

vec3 companionFaceDirection(int face, vec2 uv) {
    vec2 p = uv * 2.0 - 1.0;
    if (face == 0) return normalize(vec3(1.0, -p.y, -p.x));
    if (face == 1) return normalize(vec3(-1.0, -p.y, p.x));
    if (face == 2) return normalize(vec3(p.x, 1.0, p.y));
    if (face == 3) return normalize(vec3(p.x, -1.0, -p.y));
    if (face == 4) return normalize(vec3(p.x, -p.y, 1.0));
    return normalize(vec3(-p.x, -p.y, -1.0));
}

// Each source has its own six-face atlas allocation; no solar visibility enters
// this lookup. Four taps soften shadow edges without mixing neighbouring tiles.
vec3 companionShadow(int index, vec3 ray, float radius, vec3 normal, vec3 transmission) {
#if ENABLE_LOCAL_SHADOWS == 0
    return transmission;
#else
    vec3 absolute = abs(ray);
    vec2 uv;
    int face;
    float axis;
    if (absolute.x >= absolute.y && absolute.x >= absolute.z) {
        axis = absolute.x;
        face = ray.x > 0.0 ? 0 : 1;
        uv = ray.x > 0.0 ? vec2(-ray.z, -ray.y) : vec2(ray.z, -ray.y);
    } else if (absolute.y >= absolute.z) {
        axis = absolute.y;
        face = ray.y > 0.0 ? 2 : 3;
        uv = ray.y > 0.0 ? vec2(ray.x, ray.z) : vec2(ray.x, -ray.z);
    } else {
        axis = absolute.z;
        face = ray.z > 0.0 ? 4 : 5;
        uv = ray.z > 0.0 ? vec2(ray.x, -ray.y) : vec2(-ray.x, -ray.y);
    }
    uv = uv / max(axis, 0.001) * 0.5 + 0.5;
    vec3 result = vec3(0.0);
    float inner = float(LOCAL_SHADOW_RESOLUTION - 2);
    vec2 pixel = uv * inner - 0.5;
    vec2 fraction = fract(pixel);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            // 在相邻深度比较结果之间插值，保留四点预算并消除纹素阶梯。
            vec2 offset = (vec2(float(x), float(y)) - fraction)
                        * LOCAL_SHADOW_SOFTNESS / inner;
            vec2 sampleUv = clamp(uv + offset, vec2(0.5 / inner), vec2(1.0 - 0.5 / inner));
            vec2 pixelUv = (floor(sampleUv * inner) + 0.5) / inner;
            vec3 sampleRay = companionFaceDirection(face, pixelUv);
            float planeCosine = dot(sampleRay, normal);
            float receiverDistance = abs(planeCosine) > 0.0001
                ? dot(ray, normal) / planeCosine : length(ray);
            // Match each PCF sample to the receiver plane. A fixed central
            // distance causes severe acne for grazing point-light surfaces.
            float queryDepth = (max(receiverDistance, 0.0) - 0.025) / radius;
            vec2 depths = texture2D(companionAtlas, companionShadowUv(index * 6 + face, pixelUv)).rg;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y);
            vec3 tint = queryDepth < depths.g ? vec3(1.0) : transmission;
            result += step(queryDepth, depths.r) * tint * weight;
        }
    }
    return mix(transmission, result, LOCAL_SHADOW_STRENGTH);
#endif
}

// Unobstructed block light at a cell is the emitter level minus the Manhattan
// distance. Light that detours a few blocks around a pillar or short wall is
// still that emitter's shadow; only a long detour (another room, a doorway)
// means the native light arrived indirectly and must stay lit. No source
// explains more than the observed level.
float companionSourceWeight(float expected, float level) {
    if (expected <= 0.0) {
        return 0.0;
    }
    return blockLightAttenuation(min(expected, level) / 15.0)
         * (1.0 - smoothstep(5.0, 9.0, expected - level));
}

// rgb = radiance-weighted hue of the emitters whose propagated light reaches the
// cell, a = their weighted emission level (0 where none does). The Mod floods
// each hue with vanilla rules.
vec4 companionHue(vec3 position) {
    vec4 grid = companionMeta(3.0);
    vec3 extent = COMPANION_HUE_BRICKS * 8.0;
    if (grid.z < 0.5 || any(lessThan(position, vec3(0.0))) || any(greaterThanEqual(position, extent))) {
        return vec4(0.0);
    }
    vec2 size = companionAtlasSize();
    vec3 brick = floor(position / 8.0);
    float index = (brick.y * COMPANION_HUE_BRICKS.z + brick.z) * COMPANION_HUE_BRICKS.x + brick.x;
    float row = floor((index + 0.5) / size.x);
    // (0) unlit, (hue, -emission) single-hue brick, (slot, 0, 0, 1) pooled brick.
    vec4 entry = texture2D(companionAtlas, (vec2(index - row * size.x, grid.y + row) + 0.5) / size);
    if (entry.a < 0.0) {
        return vec4(entry.rgb, -entry.a);
    }
    if (entry.a < 0.5) {
        return vec4(0.0);
    }
    float slot = entry.r;
    float perRow = floor(size.x / 64.0);
    float slotRow = floor((slot + 0.5) / perRow);
    vec3 cell = floor(position) - brick * 8.0;
    vec2 texel = vec2((slot - slotRow * perRow) * 64.0 + cell.y * 8.0 + cell.x,
        grid.y + ceil(16384.0 / size.x) + slotRow * 8.0 + cell.z);
    return texture2D(companionAtlas, (texel + 0.5) / size);
}

// The hue grid holds one value per block, so a nearest lookup switches colour in
// whole-block steps where two emitters' light meets. Interpolate bilinearly over
// the four cells in the surface plane; only lit cells contribute, so walls and
// unlit cells beside the receiver do not pull the blend toward black.
vec4 companionSmoothHue(vec3 position, vec3 normal) {
    vec3 axis = abs(normal);
    vec3 plane = axis.x >= axis.y && axis.x >= axis.z ? vec3(0.0, 1.0, 1.0)
               : axis.y >= axis.z ? vec3(1.0, 0.0, 1.0) : vec3(1.0, 1.0, 0.0);
    vec3 first = plane.x > 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 second = plane.z > 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    // Cell centres sit at +0.5 along the tangents; the normal axis keeps its cell.
    vec3 shifted = position - 0.5 * plane;
    vec3 base = floor(shifted);
    vec2 fraction = vec2(dot(fract(shifted), first), dot(fract(shifted), second));
    vec4 sum = vec4(0.0);
    float total = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec4 tap = companionHue(base + first * float(x) + second * float(y) + 0.5);
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y) * step(0.5, tap.a);
            sum += tap * weight;
            total += weight;
        }
    }
    return total > 0.0 ? sum / total : vec4(0.0);
}

// Fraction of the native block light that reaches the receiver. Native light
// is the maximum over emitters, so a shadowed emitter removes only the share
// it explains beyond the strongest visible one. Unlisted light stays lit.
// tint weights the glass caches, which cover only the radiance volume.
vec3 companionVisibility(vec3 position, vec3 normal, float level, float observed, float tint) {
    vec3 cellPosition = floor(position + normal * 0.5) + 0.5;
    int count = int(companionHeader().y + 0.5);
    vec3 visible = vec3(0.0);
    float explained = 0.0;
    for (int index = 0; index < 128; index++) {
        if (index >= count || index >= LOCAL_LIGHT_COUNT) {
            break;
        }
        vec4 light = companionLight(index, 0);
        vec3 delta = abs(light.xyz + 0.5 - cellPosition);
        float manhattan = delta.x + delta.y + delta.z;
        // Emission never exceeds 15, so farther sources cannot reach this cell.
        if (manhattan >= 15.0) {
            continue;
        }
        float weight = companionSourceWeight(companionLight(index, 1).w - manhattan, level);
        if (weight <= 0.0) {
            continue;
        }
        explained = max(explained, weight);
        // visibility never exceeds 1, so a source no stronger than the visible
        // share already found cannot change the result; skip its shadow lookup.
        if (weight <= min(min(visible.r, visible.g), visible.b)) {
            continue;
        }
        vec4 anchor = companionLight(index, 2);
        vec3 ray = light.xyz + anchor.xyz - position;
        float squared = dot(ray, ray);
        float radius = abs(light.w);
        vec3 visibility = vec3(1.0);
        if (squared < radius * radius && squared > 0.0001) {
            // Only faces turned away from the emitter darken. Floors and walls lit
            // at grazing angles keep the isotropic native field, which is also the
            // far-camera fallback (visibility 1); a Lambert term here halved a
            // torch's lit area near the camera and doubled it again further away.
            float wrap = clamp(1.0 + 2.0 * dot(normal, ray) * inversesqrt(squared), 0.0, 1.0);
            vec3 transmission = light.w > 0.0 && tint > 0.0
                ? mix(vec3(1.0), companionTransmission(index, position), tint) : vec3(1.0);
            visibility = wrap <= 0.0 ? vec3(0.0)
                : light.w > 0.0 ? companionShadow(index, -ray, radius, normal, transmission) : transmission;
            // Maps belong to their lights, so no camera distance limits them; a
            // light entering or leaving the selection fades over a fraction of a second.
            visibility = mix(vec3(1.0), visibility * wrap, anchor.w);
        }
        visible = max(visible, visibility * weight);
    }
    if (explained <= 0.0) {
        return vec3(1.0);
    }
    return clamp(1.0 - (explained - visible) / max(observed, explained), 0.0, 1.0);
}

// One block-light model everywhere: native energy, grid hue, local visibility.
vec3 companionBlockLight(vec3 viewPosition, vec3 normalView, vec2 lmCoord, vec3 nativeRadiance) {
    // Unlit terrain has no propagated block energy to recolour or shadow.
    if (nativeRadiance.r <= 0.000001 || !hasCompanionLighting()) {
        return nativeRadiance;
    }
    float level = lightmapLevel(lmCoord.x) * 15.0;
    float observed = blockLightAttenuation(level / 15.0);
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 world = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz + cameraPosition;
    // The native tint is (1,g,b), so its red channel is the uncoloured energy.
    vec3 colour = nativeRadiance / nativeRadiance.r;
    vec3 relative = world - cameraPosition;
    float energy = nativeRadiance.r;
#if ENABLE_COLOURED_LIGHTING == 1
    // Light levels are stored in the air cell in front of the surface. The hue
    // region keeps at least 96 (48 vertical) blocks around the camera.
    vec4 hue = companionSmoothHue(world + normal * 0.5 - companionHueOrigin, normal);
    vec3 far = abs(relative);
    float coverage = step(0.5, hue.a)
        * (1.0 - smoothstep(80.0, 96.0, max(far.x, far.z))) * (1.0 - smoothstep(32.0, 48.0, far.y));
    colour = mix(colour, hue.rgb, coverage);
    // The native field reads every level as distance from a level-15 torch, so
    // weaker emitters (soul torch 10, redstone torch 7) looked nearly unlit. With
    // the emitter's level known, attenuate over its own range and scale the
    // intensity by level. The native field puts a torch's own cell two blocks
    // from its source; every emitter keeps that near field, so torches (14) and
    // brighter emitters keep exactly the native energy instead of a hot spot.
    float ownLevel = level;
#if SMOOTH_BLOCK_LIGHT == 0
    ownLevel = floor(ownLevel + 0.5);
#endif
    float own = 4.0 * BLOCK_LIGHT_STRENGTH * min(hue.a, 15.0) / 15.0
              * emitterLightAttenuation(ownLevel, min(hue.a, 15.0), 2.0);
    energy = mix(energy, max(energy, own), coverage);
#endif
    vec3 position = world - companionOrigin;
    // Glass tint caches follow the camera-centred volume; fade them like GI.
    float size = companionHeader().z;
    float tint = companionCameraFade(relative, size * 0.5 - 4.0) * companionVolumeWeight(position, size, 1.0);
    vec3 visibility = companionVisibility(position, normal, level, observed, tint);
    return colour * visibility * energy;
}

// Bilinear interpolation within padded x/y slices plus interpolation between
// z slices gives continuous 3D radiance with six texture reads for all RGB bands.
vec4 companionSh(vec3 position, float size, float band) {
    vec3 p = clamp(position - 0.5, vec3(0.0), vec3(size - 1.0));
    float first = floor(p.z);
    float second = min(first + 1.0, size - 1.0);
    float side = size + 2.0;
    float rows = ceil(size / 8.0);
    vec2 dimensions = vec2(side * 8.0, side * rows * 3.0);
    vec2 a = vec2(mod(first, 8.0), floor(first / 8.0)) * side;
    vec2 b = vec2(mod(second, 8.0), floor(second / 8.0)) * side;
    a.y += band * rows * side;
    b.y += band * rows * side;
    vec4 lower = texture2D(companionRadiance, (a + p.xy + 1.5) / dimensions);
    vec4 upper = texture2D(companionRadiance, (b + p.xy + 1.5) / dimensions);
    return mix(lower, upper, fract(p.z));
}

vec3 companionIndirect(vec3 viewPosition, vec3 normalView) {
#if GI_BOUNCES == 0
    return vec3(0.0);
#else
    if (!hasCompanionLighting() || companionHeader().w < 0.5) {
        return vec3(0.0);
    }
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 position = companionPosition(viewPosition, companionGiOrigin) + normal * 0.65;
    float size = companionHeader().z;
    // The volume moves in four-block steps; fading by its border made the
    // bounce light jump with each step. Fade by camera distance instead, which
    // is continuous; the border term only guards a volume still being rebuilt.
    vec3 relative = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
    float weight = companionCameraFade(relative, size * 0.5 - 4.0) * companionVolumeWeight(position, size, 2.0);
    if (weight <= 0.0) {
        return vec3(0.0);
    }
    vec4 basis = vec4(0.886227, -normal * 1.023327);
    return max(vec3(dot(companionSh(position, size, 0.0), basis),
                    dot(companionSh(position, size, 1.0), basis),
                    dot(companionSh(position, size, 2.0), basis)), vec3(0.0)) * GI_STRENGTH * weight;
#endif
}

#endif
