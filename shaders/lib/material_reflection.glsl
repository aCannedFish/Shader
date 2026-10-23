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
            // 双边深度权重：明显更近的前景和远得多的背景（含天空）都不进入倒影。
            // 旧版允许天空进入，物体轮廓在倒影里因此带一圈亮边。
            float weight = smoothstep(hitDepth * 0.65, hitDepth * 0.9, z)
                         * (1.0 - smoothstep(hitDepth * 1.6, hitDepth * 3.0, z));
            vec4 radiance = textureLod(scene, tap, lod);
            // Sky is filled after this pass. Mip alpha carries opaque coverage.
            // 命中的是几何体：未覆盖的部分视为未知而不是天空，按覆盖率归一化，
            // 并降低大部分是天空的纹素的权重。叶片边缘不再被天空染白。
            radiance.rgb /= max(radiance.a, 0.25);
            weight *= radiance.a;
            // 按 1/(1+亮度) 加权（Karis 平均）：少数 HDR 亮点不会主导倒影边缘。
            weight /= 1.0 + luma(radiance.rgb);
            sum += radiance.rgb * weight;
            total += weight;
        }
    }
    if (total <= EPSILON) {
        // 四个采样都被深度拒绝：退回命中像素本身。
        vec4 centre = textureLod(scene, uv, 0.0);
        return centre.rgb / max(centre.a, 0.25);
    }
    return sum / total;
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
                         * (1.0 - smoothstep(hitDepth * 1.6, hitDepth * 3.0, z))
                         * (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
            vec3 radiance = texture2D(scene, tap).rgb;
            weight /= 1.0 + luma(radiance);
            sum += radiance * weight;
            total += weight;
        }
    }
    if (total <= EPSILON) {
        return texture2D(scene, uv).rgb;
    }
    return sum / total;
#endif
}

// 屏幕外与相机看不到的遮挡由调用者用 reflection_occlusion.glsl 补足。
vec4 traceMaterialScene(sampler2D scene, sampler2D depths, vec3 origin,
                        vec3 direction, float roughness, out float distanceToHit) {
    bool thinHit;
    distanceToHit = 0.0;
    // 接收面自身在深度缓冲里，留 0.05 格的自交余量；范围覆盖整个渲染距离，
    // 积水和光滑地面里远处的山不再渐变成天空。
    vec4 hit = traceScreenReflection(depths, origin, direction, 0.05, far,
                                      MATERIAL_REFLECTION_STEPS, thinHit);
    if (hit.a <= 0.0) {
        return vec4(0.0);
    }
#ifdef MATERIAL_REFLECTION_MIPS
    // The opaque receiver uses this same quantized normal to launch its ray.
    // Reject its outgoing hemisphere too, even if quantization tilts that ray
    // slightly into the true depth plane at an extreme grazing angle.
    // A thin hit enters through a face the camera cannot see, so the visible
    // face normal says nothing about the struck face and is not tested.
    vec3 hitNormal = decodeNormal(texture2D(colortex1, reflectionPixelUv(hit.xy)).rg);
    if (!thinHit && (dot(hitNormal, direction) >= 0.0
        || dot(hitNormal, -(origin + direction * hit.z)) <= 0.0)) {
        return vec4(0.0);
    }
#endif
    distanceToHit = hit.z;
    float hitDepth = reflectionSceneDepth(depths, hit.xy);
    return vec4(filterMaterialHit(scene, depths, hit.xy, hitDepth, hit.z, roughness), hit.a);
}

vec4 traceMaterialScene(sampler2D scene, sampler2D depths, vec3 origin,
                        vec3 direction, float roughness) {
    float distanceToHit;
    return traceMaterialScene(scene, depths, origin, direction, roughness, distanceToHit);
}

#endif
