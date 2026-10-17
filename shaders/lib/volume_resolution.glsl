/* Shared viewport shape for clouds, air scattering and underwater shafts.
 * Buffers keep full attachment sizes; generation and reconstruction must agree
 * on the active lower-left region, including odd internal render dimensions.
 */
#ifndef LIB_VOLUME_RESOLUTION_GLSL
#define LIB_VOLUME_RESOLUTION_GLSL
#include "../settings.glsl"
#include "uniforms.glsl"

vec2 volumeSize() {
#if VOLUMETRIC_RESOLUTION == 0
    return max(floor(vec2(viewWidth, viewHeight) * 0.25), vec2(1.0));
#else
    return max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
#endif
}
#endif
