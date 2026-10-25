/* Single-bounce screen reflection with a deterministic roughness filter.
 * The source colour/depth pair is immutable for the entire pass, so reflective
 * neighbours cannot recursively read each other's partially written results.
 */
#ifndef LIB_MATERIAL_REFLECTION_GLSL
#define LIB_MATERIAL_REFLECTION_GLSL
#include "materials.glsl"
#include "screen_reflection.glsl"
#include "screen_reflection_adaptive.glsl"
#include "reflection_source.glsl"
#include "reflection_medium.glsl"
#include "atmosphere.glsl"
#include "lightmap.glsl"
#include "material_environment.glsl"

vec4 filterMaterialHit(sampler2D scene, sampler2D depths, vec2 uv,
                       float hitDepth, float distance, float roughness) {
    return reflectionSourceFiltered(scene, depths, uv, hitDepth, distance, roughness);
}

// 屏幕外与相机看不到的遮挡由调用者用 reflection_occlusion.glsl 补足。
vec4 traceMaterialScene(sampler2D scene, sampler2D depths, vec3 origin,
                        vec3 direction, float roughness, float analyticalCoverage,
                        out float distanceToHit) {
    distanceToHit = 0.0;
#ifdef WORLD_GPU_BACKEND
    return worldMaterialReflection(scene, depths, origin, direction, roughness,
        analyticalCoverage, distanceToHit);
#else
    vec4 hit = traceAdaptiveReflection(scene, depths, origin, direction, 0.001, far,
        MATERIAL_REFLECTION_STEPS, vec4(0.0));
    if (hit.a <= 0.0) return vec4(0.0);
    distanceToHit = hit.z;
    float hitDepth = reflectionSceneDepth(depths, hit.xy);
    vec4 filtered = filterMaterialHit(scene, depths, hit.xy, hitDepth, hit.z, roughness);
    return vec4(reflectionAirMedium(filtered.rgb, hit.z, direction), hit.a * filtered.a);
#endif
}

vec4 traceMaterialScene(sampler2D scene, sampler2D depths, vec3 origin,
                        vec3 direction, float roughness, out float distanceToHit) {
    return traceMaterialScene(scene, depths, origin, direction, roughness, 1.0, distanceToHit);
}

vec4 traceMaterialScene(sampler2D scene, sampler2D depths, vec3 origin,
                        vec3 direction, float roughness) {
    float distanceToHit;
    return traceMaterialScene(scene, depths, origin, direction, roughness, distanceToHit);
}

#endif
