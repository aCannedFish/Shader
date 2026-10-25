/* A reflection source is surface radiance, without camera fog. Apply only the
 * reflected air segment here; the receiving surface applies its own segment.
 */
#ifndef LIB_REFLECTION_MEDIUM_GLSL
#define LIB_REFLECTION_MEDIUM_GLSL
#include "fog.glsl"
#include "sky.glsl"

vec3 reflectionAirMedium(vec3 radiance, float distance, vec3 viewDirection) {
#ifdef WORLD_GPU_BACKEND
    if (isEyeInWater != 0) return radiance;
    float opacity = getFogFactor(distance);
    if (opacity <= 0.0) return radiance;
    vec3 colour = getFogColor();
#if SIMPLE_DIMENSION == 0
    vec3 direction = normalize(mat3(gbufferModelViewInverse) * viewDirection);
    colour = skyAtmosphereRadiance(direction);
#endif
    return mix(radiance, colour, opacity);
#else
    return radiance;
#endif
}
#endif
