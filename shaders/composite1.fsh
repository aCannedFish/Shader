#version 120
/* composite1.fsh: sky, water optics and depth-aware cloud reconstruction. */
/* RENDERTARGETS: 0 */
#include "lib/clouds.glsl"
#include "lib/sky_background.glsl"
#include "lib/water_reflection.glsl"
uniform sampler2D colortex0;
uniform sampler2D colortex4;
uniform sampler2D depthtex0;
#include "lib/underwater.glsl"

// Neighbour depths reject cloud samples from the other side of a foreground
// silhouette. No temporal history is needed, so captures remain deterministic.
vec4 upsampleClouds(vec2 uv, float distance) {
    vec3 ray = getCloudRayWorld(uv);
    float entry;
    float exit;
    if (isEyeInWater == 1 || !cloudRayInterval(cameraPosition, ray, distance, entry, exit)) {
        return vec4(0.0);
    }
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    vec4 sum = vec4(0.0);
    float total = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 sampleUv = clamp((base + vec2(float(x), float(y)) + 0.5) / size,
                                  0.5 / size, 1.0 - 0.5 / size);
            float depth = texture2D(depthtex0, sampleUv).r;
            float neighbourDistance = depth < 0.999999 ? length(screenToView(sampleUv, depth)) : CLOUD_DISTANCE;
            float spatial = (x == 0 ? 1.0 - fraction.x : fraction.x)
                          * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = spatial * exp(-abs(neighbourDistance - distance) / max(distance * 0.10, 0.5));
            sum += texture2D(colortex4, sampleUv * size / vec2(viewWidth, viewHeight)) * weight;
            total += weight;
        }
    }
    return total > 0.00001 ? sum / total : vec4(0.0);
}

void main() {
    vec2 screenCoord = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    float depth = texture2D(depthtex0, screenCoord).r;
    vec3 color = fillSkyBackground(texture2D(colortex0, screenCoord).rgb, screenCoord, depth);
    float sceneDistance = depth < 0.999999 ? length(screenToView(screenCoord, depth)) : CLOUD_DISTANCE;
    float waterDepth = texture2D(colortex5, screenCoord).a;
    if (waterDepth > 0.001 && isEyeInWater == 0) {
        vec3 waterPosition = waterSurfacePosition(screenCoord, waterDepth);
        sceneDistance = min(sceneDistance, length(waterPosition));
        color = applyWaterReflection(texture2D(colortex0, screenCoord).rgb, screenCoord, waterPosition);
    }
    if (isEyeInWater == 1) {
        color = applyUnderwaterOptics(screenCoord, depth);
    } else if (depth < 0.999999 || waterDepth > 0.001) {
        color = correctSkyFog(color, screenCoord, sceneDistance);
    }
    vec4 cloud = upsampleClouds(screenCoord, sceneDistance);
    color = cloud.rgb + color * (1.0 - cloud.a);
    gl_FragData[0] = vec4(color, 1.0);
}
