/* Surface material lighting shares solar transmission and the companion's
 * existing per-light visibility. Local specular is never gated by solar shadow.
 */
#ifndef LIB_MATERIAL_LIGHTING_GLSL
#define LIB_MATERIAL_LIGHTING_GLSL
#include "materials.glsl"
#include "lighting.glsl"
#include "space.glsl"
#include "material_environment.glsl"

vec3 materialPointSpecular(SurfaceMaterial m, vec3 normalView, vec3 viewPosition) {
    if (!hasCompanionLighting()) {
        return vec3(0.0);
    }
    vec3 position = companionPosition(viewPosition, companionOrigin);
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 view = normalize(mat3(gbufferModelViewInverse) * -viewPosition);
#ifndef WORLD_GPU_BACKEND
    float size = companionHeader().z;
    float tint = companionVolumeWeight(position, size, 1.0);
#endif
    int count = int(companionHeader().y + 0.5);
    vec3 sum = vec3(0.0);
    for (int index = 0; index < LOCAL_LIGHT_COUNT; index++) {
        if (index >= count) {
            break;
        }
        vec4 light = companionLight(index, 0);
        vec4 anchor = companionLight(index, 2);
        vec3 ray = light.xyz + anchor.xyz - position;
        float squared = dot(ray, ray);
        float radius = abs(light.w);
        // Unmapped sources wait for their visibility map instead of leaking a
        // sharp highlight through a wall. Their native diffuse light remains.
        if (light.w <= 0.0 || squared >= radius * radius || squared <= 0.0001
            || dot(normal, ray) <= 0.0 || anchor.w <= 0.001) {
            continue;
        }
        vec4 source = companionLight(index, 1);
        float window = max(1.0 - squared * squared / pow(radius, 4.0), 0.0);
#ifdef WORLD_GPU_BACKEND
        WorldPosition receiver = worldPosition(viewToWorld(viewPosition), cameraPosition);
        vec3 transmission = worldPointGlassFilter(colortex6, index, receiver, normal);
#else
        vec3 transmission = mix(vec3(1.0), companionTransmission(index, position), tint);
#endif
        vec3 visibility = companionShadow(index, -ray, radius, normal, transmission);
        vec3 radiance = source.rgb * window * window / (1.0 + squared)
                      * BLOCK_LIGHT_STRENGTH * anchor.w;
        sum += materialLightSpecular(m, normal, view, ray * inversesqrt(squared),
                                     radiance * visibility);
    }
#ifdef WORLD_GPU_BACKEND
    sum *= materialAnalyticEmitterWeight(m.roughness);
#endif
    return sum;
}

vec3 materialDirectSpecular(SurfaceMaterial m, vec3 normal, vec3 viewPosition,
                           vec2 lmCoord, vec3 shadow) {
#if SIMPLE_DIMENSION != 0
    return materialPointSpecular(m, normal, viewPosition);
#endif
    vec3 view = safeNormalize(-viewPosition, normal);
    vec3 solar = materialLightSpecular(m, normal, view, normalize(sunPosition), getSunLightColor())
               + materialLightSpecular(m, normal, view, normalize(moonPosition), getMoonLightColor());
    if (any(greaterThan(solar, vec3(0.0)))) {
        float sky = smoothstep(0.60, 0.96, lightmapLevel(lmCoord.y));
        float cloud = cloudProjectedShadow(viewToAbsoluteWorld(viewPosition),
            normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
        solar *= shadow * sky * cloud;
    }
    return solar + materialPointSpecular(m, normal, viewPosition);
}

#endif
