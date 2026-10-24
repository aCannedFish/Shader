#ifndef SIMPLE_WORLD_POINT_LIGHTING_GLSL
#define SIMPLE_WORLD_POINT_LIGHTING_GLSL
#include "/lib/world/point_shadow.glsl"
#include "/lib/world/glass_cache.glsl"

// Source colour and geometric influence are separate from native block-light
// energy. The lighting caller can preserve its calibrated brightness while
// replacing the companion's colour and independent visibility providers.
vec3 worldPointLightInfluence(sampler2D data, WorldPosition receiver, vec3 normal,
    out float explainedWeight) {
    vec3 colour = vec3(0.0);
    explainedWeight = 0.0;
    for (int slot = 0; slot < WORLD_POINT_LIGHT_COUNT; slot++) {
        WorldPointLight light = worldReadPointLight(data, slot);
        if (!light.valid) continue;
        vec3 ray = vec3(light.position.block - receiver.block)
            + light.position.fraction - receiver.fraction;
        float squared = max(dot(ray, ray), 0.0001);
        float fraction = squared / max(light.radius * light.radius, 0.0001);
        if (fraction >= 1.0) continue;
        float cutoff = 1.0 - fraction * fraction;
        float weight = cutoff * cutoff / (1.0 + squared);
        float wrap = clamp(1.0 + 2.0 * dot(normal, ray) * inversesqrt(squared), 0.0, 1.0);
        float visibility = worldPointShadowVisibility(data, slot, -ray, light.radius, normal);
        vec3 transmission = visibility > 0.0 ? worldPointGlassFilter(data, slot, receiver, normal) : vec3(1.0);
        colour += light.emission * weight * wrap * visibility * transmission;
        explainedWeight += weight;
    }
    return colour;
}
#endif
