#version 120
/* composite.fsh: half-resolution cloud radiance and optical opacity. */
/* RENDERTARGETS: 4 */
#include "lib/clouds.glsl"
#include "lib/volume_resolution.glsl"
#include "lib/space.glsl"
#include "lib/water.glsl"
uniform sampler2D depthtex0;
uniform sampler2D colortex5;

void main() {
    if (isEyeInWater == 1) {
        float immersion = 0.0;
        if (gl_FragCoord.x < 1.0 && gl_FragCoord.y < 1.0) {
            immersion = estimateWaterImmersion(colortex5);
        }
        gl_FragData[0] = vec4(immersion, 0.0, 0.0, 0.0);
        return;
    }
    vec2 size = volumeSize();
    vec2 uv = gl_FragCoord.xy / size;
    float depth = texture2D(depthtex0, uv).r;
    float limit = depth < 0.999999 ? length(screenToView(uv, depth)) : CLOUD_DISTANCE;
    float waterDepth = texture2D(colortex5, uv).a;
    if (waterDepth > 0.001 && isEyeInWater == 0) {
        vec3 viewRay = screenToView(uv, 0.5);
        limit = min(limit, length(viewRay * waterDepth / max(-viewRay.z, EPSILON)));
    }
    gl_FragData[0] = traceVolumetricClouds(getCloudRayWorld(uv), limit);
}
