/* 通用表面BRDF与反射权重。具体材质参数由资源包LabPBR贴图提供。 */
#ifndef LIB_MATERIALS_GLSL
#define LIB_MATERIALS_GLSL
#include "../settings.glsl"
#include "common.glsl"

struct SurfaceMaterial {
    vec3 f0;
    float roughness;
    float metallic;
};

// Smooth mirrors retain the emitter image. Rough surfaces use its integrated
// point-light lobe; the two representations must share one energy budget.
float materialAnalyticEmitterWeight(float roughness) {
    return smoothstep(0.12, 0.18, roughness);
}

vec3 materialFresnel(vec3 f0, float cosine) {
    float edge = pow(1.0 - clamp(cosine, 0.0, 1.0), 5.0);
    return f0 + (1.0 - f0) * edge;
}

// Analytic GGX environment BRDF integral (Lazarov's split-sum fit). A single
// mirror Fresnel factor overestimates grazing reflections on rough dielectrics.
vec3 materialEnvironmentWeight(SurfaceMaterial m, float cosine) {
    vec4 r = m.roughness * vec4(-1.0, -0.0275, -0.572, 0.022)
           + vec4(1.0, 0.0425, 1.04, -0.04);
    float a004 = min(r.x * r.x, exp2(-9.28 * clamp(cosine, 0.0, 1.0))) * r.x + r.y;
    vec2 integrated = vec2(-1.04, 1.04) * a004 + r.zw;
    return clamp(m.f0 * integrated.x + integrated.y, vec3(0.0), vec3(1.0));
}

// A shading normal may reflect below the actual surface at a grazing angle.
// Smith masking removes that impossible lobe; its energy remains in the
// diffuse/transmitted branch instead of reading an unrelated sky direction.
float reflectionGeometricVisibility(float viewCosine, float lightCosine, float roughness) {
    if (viewCosine <= 0.0 || lightCosine <= 0.0) return 0.0;
    float alpha = max(roughness * roughness, 0.001);
    float squared = alpha * alpha;
    float view = 2.0 * viewCosine / (viewCosine
        + sqrt(squared + (1.0 - squared) * viewCosine * viewCosine));
    float light = 2.0 * lightCosine / (lightCosine
        + sqrt(squared + (1.0 - squared) * lightCosine * lightCosine));
    return view * light;
}

// GGX NDF and height-correlated Smith visibility; includes NdotL and Fresnel.
vec3 materialLightSpecular(SurfaceMaterial m, vec3 normal, vec3 view,
                          vec3 light, vec3 radiance) {
    float nl = max(dot(normal, light), 0.0);
    float viewCosine = dot(normal, view);
    if (nl <= 0.0 || viewCosine <= 0.0 || !any(greaterThan(radiance, vec3(0.0)))) {
        return vec3(0.0);
    }
    float nv = max(viewCosine, 0.001);
    vec3 halfway = safeNormalize(view + light, normal);
    float nh = max(dot(normal, halfway), 0.0);
    float vh = max(dot(view, halfway), 0.0);
    float alpha = max(m.roughness * m.roughness, 0.01);
    float a2 = alpha * alpha;
    float denominator = nh * nh * (a2 - 1.0) + 1.0;
    float distribution = a2 / max(PI * denominator * denominator, 0.0000001);
    float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2);
    float gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
    float visibility = 0.5 / max(gv + gl, 0.00001);
    return radiance * materialFresnel(m.f0, vh) * distribution * visibility * nl;
}
// 各向异性GGX。切线来自原生UV方向，提供刷纹方向的宽高光，不采样场景镜像。
vec3 materialAnisotropicSpecular(SurfaceMaterial m, vec3 normal, vec3 tangent, vec3 view,
                                vec3 light, vec3 radiance, float anisotropy) {
    float nv = dot(normal, view);
    float nl = dot(normal, light);
    if (nv <= 0.0 || nl <= 0.0 || !any(greaterThan(radiance, vec3(0.0)))) return vec3(0.0);
    tangent = safeNormalize(tangent - normal * dot(normal, tangent),
        abs(normal.y) < 0.9 ? normalize(cross(normal, vec3(0.0, 1.0, 0.0)))
        : normalize(cross(normal, vec3(1.0, 0.0, 0.0))));
    vec3 bitangent = cross(normal, tangent);
    float alpha = max(m.roughness * m.roughness, 0.01);
    float aspect = sqrt(1.0 - 0.9 * clamp(anisotropy, 0.0, 0.9));
    vec2 axes = vec2(alpha / aspect, alpha * aspect);
    vec3 halfVector = safeNormalize(view + light, normal);
    vec2 h = vec2(dot(halfVector, tangent), dot(halfVector, bitangent)) / axes;
    float nh = max(dot(normal, halfVector), 0.0);
    float denominator = dot(h, h) + nh * nh;
    float distribution = 1.0 / max(PI * axes.x * axes.y * denominator * denominator, 1e-8);
    vec2 v = vec2(dot(view, tangent), dot(view, bitangent)) * axes;
    vec2 l = vec2(dot(light, tangent), dot(light, bitangent)) * axes;
    float lambdaV = sqrt(1.0 + dot(v, v) / max(nv * nv, 1e-8));
    float lambdaL = sqrt(1.0 + dot(l, l) / max(nl * nl, 1e-8));
    float masking = 2.0 / (lambdaV + lambdaL);
    return radiance * materialFresnel(m.f0, max(dot(view, halfVector), 0.0))
        * distribution * masking / max(4.0 * nv, 0.00001);
}
#endif
