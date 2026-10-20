/* Low-frequency reflected radiance shared by forward shading and SSR.
 * A complete base radiance prevents another metal surface from appearing black
 * in the first reflection bounce, before the screen reflection pass runs.
 */
#ifndef LIB_MATERIAL_ENVIRONMENT_GLSL
#define LIB_MATERIAL_ENVIRONMENT_GLSL
#include "atmosphere.glsl"
#include "lightmap.glsl"

// The native light field supplies low-frequency local radiance when reflected
// geometry is off screen. It never fabricates an unoccluded solar highlight.
vec3 materialAmbientEnvironment(vec3 directionWorld, vec2 lmCoord) {
#if SIMPLE_DIMENSION != 0
    vec3 environment = dimensionAmbient(directionWorld) * AMBIENT_STRENGTH;
#if SIMPLE_DIMENSION == 1
    environment = mix(environment, dimensionBackground(directionWorld) * 1.8,
                      END_ATMOSPHERE * 0.65 * smoothstep(-0.2, 0.5, directionWorld.y));
#endif
    return environment + blockLightRadiance(lmCoord);
#else
    float sky = smoothstep(0.02, 0.95, lightmapLevel(lmCoord.y));
    vec3 environment = toLinearSpace(skyColor) * mix(0.15, 0.65, skyDaylight())
                     * mix(0.30, 1.0, directionWorld.y * 0.5 + 0.5);
    return environment * sky + blockLightRadiance(lmCoord);
#endif
}
#endif
