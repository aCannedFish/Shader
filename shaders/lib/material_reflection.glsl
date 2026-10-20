/* Single-bounce screen reflection with a deterministic roughness filter.
 * The source colour/depth pair is immutable for the entire pass, so reflective
 * neighbours cannot recursively read each other's partially written results.
 */
#ifndef LIB_MATERIAL_REFLECTION_GLSL
#define LIB_MATERIAL_REFLECTION_GLSL
#include "materials.glsl"
#include "screen_reflection.glsl"
#include "atmosphere.glsl"
#include "lightmap.glsl"
#include "material_environment.glsl"

vec3 filterMaterialHit(sampler2D scene, sampler2D depths, vec2 uv,
                       float hitDepth, float distance, float roughness) {
    float radius = roughness * roughness * min(viewWidth, viewHeight) * 0.045
                 * clamp(distance / max(hitDepth, 1.0), 0.25, 2.0);
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
#ifdef MATERIAL_REFLECTION_MIPS
    // Hardware trilinear mip filtering integrates a continuous footprint.
    // Sparse, widely spaced taps duplicate leaf/grass contours instead of blur.
    float lod = max(log2(max(radius * 2.0, 1.0)), 0.0);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int x = -1; x <= 1; x += 2) {
        for (int y = -1; y <= 1; y += 2) {
            vec2 tap = clamp(uv + vec2(float(x), float(y)) * radius * 0.35 * texel,
                             texel, 1.0 - texel);
            float depth = texture2D(depths, tap).r;
            float z = depth < 0.999999 ? -screenToView(tap, depth).z : far;
            float weight = smoothstep(hitDepth * 0.65, hitDepth * 0.9, z);
            vec4 radiance = textureLod(scene, tap, lod);
            // Sky is filled after this pass. Mip alpha carries opaque coverage,
            // so alpha-tested foliage cannot drag black clear colour into it.
            radiance.rgb += sceneSkyBackground(tap) * (1.0 - radiance.a);
            sum += radiance.rgb * weight;
            total += weight;
        }
    }
    return sum / max(total, EPSILON);
#else
    // Transparent geometry has no mip chain for its immutable opaque copy.
    // Keep its small footprint dense instead of sampling separated image copies.
    radius = min(radius, 2.0);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 tap = clamp(uv + vec2(float(x), float(y)) * radius * texel, texel, 1.0 - texel);
            float depth = texture2D(depths, tap).r;
            float z = depth < 0.999999 ? -screenToView(tap, depth).z : far;
            float weight = smoothstep(hitDepth * 0.65, hitDepth * 0.9, z)
                         * (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
            sum += texture2D(scene, tap).rgb * weight;
            total += weight;
        }
    }
    return sum / max(total, EPSILON);
#endif
}

vec4 traceMaterialScene(sampler2D scene, sampler2D depths, vec3 origin,
                        vec3 direction, float roughness) {
    vec4 hit = traceScreenReflection(depths, origin, direction, min(far, 64.0),
                                      MATERIAL_REFLECTION_STEPS);
    if (hit.a <= 0.0) {
        return vec4(0.0);
    }
#ifdef MATERIAL_REFLECTION_MIPS
    // The opaque receiver uses this same quantized normal to launch its ray.
    // Reject its outgoing hemisphere too, even if quantization tilts that ray
    // slightly into the true depth plane at an extreme grazing angle.
    vec3 hitNormal = decodeNormal(texture2D(colortex1, reflectionPixelUv(hit.xy)).rg);
    if (dot(hitNormal, direction) >= 0.0
        || dot(hitNormal, -(origin + direction * hit.z)) <= 0.0) {
        return vec4(0.0);
    }
#endif
    float hitDepth = reflectionSceneDepth(depths, hit.xy);
    return vec4(filterMaterialHit(scene, depths, hit.xy, hitDepth, hit.z, roughness), hit.a);
}

#endif
