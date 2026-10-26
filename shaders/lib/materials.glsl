/* Built-in material models for vanilla blocks. IDs come from block.properties;
 * unmapped blocks retain the matte surface model. Roughness is perceptual,
 * F0 is linear reflectance, and conductors have no diffuse component.
 */
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

float blockMaterialClass(float blockId) {
#if ENABLE_MATERIAL_REFLECTIONS == 0
    return 0.0;
#else
    // Block IDs are discrete even when a legacy varying interpolates them.
    // Round first so a value just below 300 cannot become a matte iron pixel.
    int id = int(floor(blockId + 0.5));
    if (id == 110 || id == 111) {
        return 12.0;
    }
    if (id >= 300 && id <= 310) {
        return float(id - 299);
    }
    if (id == 311) {
        return 14.0;
    }
    return 0.0;
#endif
}

SurfaceMaterial surfaceMaterial(float kind, float detail) {
    SurfaceMaterial m;
    m.f0 = vec3(0.04);
    m.roughness = 0.85;
    m.metallic = 0.0;
    if (kind < 0.5) {
        return m;
    }
    if (kind < 1.5) {
        m.f0 = vec3(0.56, 0.57, 0.58);
        m.roughness = 0.25;
        m.metallic = 1.0;
    } else if (kind < 2.5) {
        m.f0 = vec3(0.98, 0.71, 0.29);
        m.roughness = 0.19;
        m.metallic = 1.0;
    } else if (kind < 3.5) {
        m.f0 = vec3(0.92, 0.45, 0.28);
        m.roughness = 0.26;
        m.metallic = 1.0;
    } else if (kind < 4.5) {
        // Weathered copper is dominated by a rough dielectric patina.
        m.roughness = 0.62;
    } else if (kind < 5.5) {
        m.f0 = vec3(0.24, 0.22, 0.20);
        m.roughness = 0.42;
        m.metallic = 1.0;
    } else if (kind < 6.5) {
        m.roughness = 0.30;
    } else if (kind < 7.5) {
        m.roughness = 0.40;
    } else if (kind < 8.5) {
        m.roughness = 0.22;
    } else if (kind < 9.5) {
        // Obsidian is diffuse-dominant, with only a weak, very broad specular lobe.
        m.f0 = vec3(0.020);
        m.roughness = 0.85;
    } else if (kind < 10.5) {
        m.f0 = vec3(0.065);
        m.roughness = 0.20;
    } else if (kind < 11.5) {
        m.f0 = vec3(0.020);
        m.roughness = 0.16;
    } else if (kind < 12.5) {
        m.roughness = 0.085;
    } else {
        m.f0 = vec3(0.17);
        m.roughness = 0.16;
    }
    // Preserve the texture's brightness pattern in metallic reflections without
    // treating the original sRGB texture as measured conductor reflectance.
    m.f0 *= mix(1.0, mix(0.45, 1.0, detail), m.metallic);
    m.roughness = clamp(m.roughness + (0.5 - detail) * 0.06, 0.085, 0.95);
    return m;
}

// One RGBA8 alpha byte stores a class and sixteen texture-brightness levels.
float packMaterial(float kind, float detail) {
    return (kind * 16.0 + floor(clamp(detail, 0.0, 1.0) * 15.0 + 0.5)) / 255.0;
}

vec2 unpackMaterial(float encoded) {
    float byte = floor(encoded * 255.0 + 0.5);
    float kind = floor(byte / 16.0);
    return vec2(kind, mod(byte, 16.0) / 15.0);
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
#endif
