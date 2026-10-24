#include "/lib/world/gi.glsl"
#include "/lib/world/coverage.glsl"
#include "/lib/world/storage.glsl"
#ifdef WORLD_FULL_RENDERER
#include "/lib/lighting.glsl"
#else
uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform mat4 gbufferModelViewInverse;
#endif
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
layout(location=0) out vec4 result;

uint giLightIdentity() {
    uint signature = 0u;
    for (int slot = 0; slot < WORLD_POINT_LIGHT_COUNT; slot++) {
        WorldPointLight light = worldReadPointLight(colortex6, slot);
        if (!light.valid) continue;
        vec4 material = texelFetch(colortex6, worldLightTablePixel(WORLD_LIGHT_HEADER_SIZE + slot * 4 + 3), 0);
        uvec3 p = uvec3(light.position.block);
        uint key = p.x * 1664525u ^ p.y * 1013904223u ^ p.z * 2246822519u
            ^ uint(round(material.x + material.y * 256.0)) * 3266489917u;
        key ^= key >> 16u;
        key *= 0x7feb352du;
        signature += key ^ (key >> 15u);
    }
    return signature;
}

bool giStaticEdit(ivec3 origin) {
    ivec3 farOrigin = worldReadOrigin(colortex6, false);
    ivec3 coverOrigin = worldCoverageOrigin(farOrigin);
    ivec3 low = max(worldFloorDivide(origin - coverOrigin, 8), ivec3(0));
    ivec3 high = min(worldFloorDivide(origin + WORLD_GI_SIZE - 1 - coverOrigin, 8), worldCoverageShape() - 1);
    for (int z = 0; z < 8; z++) {
        if (low.z + z > high.z) break;
        for (int y = 0; y < 8; y++) {
            if (low.y + y > high.y) break;
            for (int x = 0; x < 8; x++) {
                if (low.x + x > high.x) break;
                ivec2 pixel = worldRegion(WORLD_REGION_FAR_COVERAGE).xy
                    + worldVoxelAddress(low + ivec3(x, y, z), worldCoverageShape(), 0, 0);
                if ((int(round(texelFetch(colortex6, pixel, 0).y)) & 1) != 0) return true;
            }
        }
    }
    return false;
}

// Geometry and emitter changes restart the working snapshot. Animated changes
// are consumed by the next snapshot rather than preventing every cycle from
// completing. Direct shadow scheduling remains independent of this state.
void main() {
    ivec2 local = ivec2(gl_FragCoord.xy) - worldRegion(WORLD_REGION_GI_CONTROL).xy;
    result = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0);
    if (local.y != 0) return;
    WorldGiState state = worldGiState(colortex6);
    vec4 config = vec4(GI_BOUNCES, GI_PROPAGATION_STEPS, GI_REFLECTANCE, 1062.0);
    uint lightIdentity = giLightIdentity();
    vec4 previousConfig = worldGiHeader(colortex6, 8);
    bool changedConfig = previousConfig.x != config.x || previousConfig.y != config.y
        || abs(previousConfig.z - config.z) > 0.001 || previousConfig.w != config.w;
    bool reset = !state.valid || changedConfig
        || worldDecodeUint(worldGiHeader(colortex6, 12)) != lightIdentity || giStaticEdit(state.origin);
    if (reset) {
        state.bounce = 0;
        state.iteration = 0;
        state.origin = worldGiCurrentOrigin(colortex6);
        state.publishedOrigin = state.origin;
        state.ready = false;
    }
    if (GI_BOUNCES == 0) state.ready = false;
    if (local.x == 0) result = vec4(1061.0, state.bounce, state.iteration, state.ready ? 1.0 : 0.0);
    if (local.x >= 1 && local.x <= 3) result = worldEncodeInt(state.origin[local.x - 1]);
    if (local.x >= 4 && local.x <= 6) result = worldEncodeInt(state.publishedOrigin[local.x - 4]);
    if (local.x == 7) result = worldEncodeUint(worldReadGeneration(colortex6));
    if (local.x == 8) result = config;
    if (local.x == 9 && reset) result = worldEncodeInt(-1);
    if (local.x == 12) result = worldEncodeUint(lightIdentity);
    if (state.bounce == 0 && state.iteration == 0) {
        vec3 direction = mat3(gbufferModelViewInverse) * shadowLightPosition;
        direction = length(direction) > 0.0001 ? normalize(direction) : vec3(0.0, 1.0, 0.0);
        vec3 sun = mat3(gbufferModelViewInverse) * sunPosition;
        sun = length(sun) > 0.0001 ? normalize(sun) : vec3(0.0, 1.0, 0.0);
        vec3 colour = sun.y > 0.0 ? vec3(2.0, 1.90, 1.70) * smoothstep(0.0, 0.06, sun.y)
            : vec3(0.024, 0.026, 0.030) * smoothstep(0.0, 0.08, direction.y);
#ifdef WORLD_FULL_RENDERER
        colour = dot(normalize(shadowLightPosition), normalize(sunPosition)) > 0.0
            ? getSunLightColor() : getMoonLightColor();
#if SIMPLE_DIMENSION != 0
        colour = vec3(0.0);
#endif
#endif
        if (local.x == 13) result = vec4(direction, 0.0);
        if (local.x == 14) result = vec4(colour, 0.0);
    }
}
