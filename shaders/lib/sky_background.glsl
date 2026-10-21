/* The entire uncovered background shares one atmosphere and celestial model. */
#ifndef LIB_SKY_BACKGROUND_GLSL
#define LIB_SKY_BACKGROUND_GLSL
#include "sky.glsl"
#include "space.glsl"
#include "fog.glsl"

vec3 sceneSkyBackground(vec2 uv) {
    return skyRadiance(skyViewDirection(uv));
}

vec3 fillSkyBackground(vec3 color, vec2 uv, float depth) {
    if (depth >= 0.999999) {
        return sceneSkyBackground(uv);
    }
    return color;
}

// Geometry already contains the original loading-distance fog. Replace only
// its colour contribution, preserving attenuation. After weather blending,
// backgroundTransmission prevents the correction from colouring rain streaks.
vec3 correctSkyFog(vec3 color, vec2 uv, float viewDistance, float backgroundTransmission) {
    if (isEyeInWater != 0) {
        return color;
    }
    float factor = getFogFactor(viewDistance);
    // Nearby surfaces and fully opaque weather have no fog-colour correction.
    // Skip the sky direction, angular lookup and texture read for zero weight.
    if (factor <= 0.0 || backgroundTransmission <= 0.0) {
        return color;
    }
    return color + (skyAtmosphereRadiance(skyViewDirection(uv)) - getFogColor())
                 * factor * backgroundTransmission;
}

#endif
