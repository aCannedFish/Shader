/* Compose the medium once after water/glass optics consumed opaque colour. */
/* RENDERTARGETS: 0 */
uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D colortex4;
uniform sampler2D colortex5;
uniform sampler2D depthtex1;
#include "/lib/clouds.glsl"
#include "/lib/water.glsl"
#include "/lib/atmosphere_media.glsl"
#include "/lib/volume_resolution.glsl"
#include "/lib/water_effects.glsl"
#include "/lib/water_shafts_filter.glsl"
#include "/lib/volume_reconstruction.glsl"
layout(location=0) out vec4 result;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    vec3 colour = texture2D(colortex0, uv).rgb;
    float depth = texture2D(depthtex1, uv).r;
    float surface = readWaterSurface(colortex5, colortex1, uv).a;
    if (isEyeInWater == 1) {
        float path = underwaterVisiblePath(uv, depth, surface, estimateUnderwaterDepth());
        result = vec4(colour + sampleWaterShafts(uv, path), 1.0);
        return;
    }
    float distance = depth < 0.999999 ? length(screenToView(uv, depth)) : CLOUD_DISTANCE;
    if (surface > 0.001) distance = min(distance, length(waterSurfacePosition(uv, surface)));
    vec4 medium = upsampleClouds(uv, distance);
    result = vec4(medium.rgb + colour * (1.0 - medium.a), 1.0);
}
