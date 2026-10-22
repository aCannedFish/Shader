/* Rain impacts use the same neutral illumination and palette as rain streaks.
 * Classification follows texture and vertex tint together; other particle hues
 * retain their ordinary lighting, including bright soul-fire textures.
 */
#ifndef LIB_RAIN_PARTICLES_GLSL
#define LIB_RAIN_PARTICLES_GLSL
#include "lighting.glsl"
#include "weather.glsl"

vec3 shadeRainParticle(vec3 original, vec3 rawAlbedo, vec2 lightmap) {
    float weight = rainParticleWeight(rawAlbedo);
    if (weight <= 0.0) {
        return original;
    }
    vec3 illumination = surfaceAmbient(lightmap, 1.0)
                      + (getSunLightColor() + getMoonLightColor()) * 0.12;
    float intensity = luma(illumination) * mix(0.6, 1.2, luma(rawAlbedo));
    return mix(original, toLinearSpace(rainDropAlbedo()) * intensity, weight);
}
#endif
