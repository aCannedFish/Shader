/* Depth-aware reconstruction of the reduced air/cloud field. Callers declare
 * the common depth, water and volume samplers before including this module. */
#ifndef LIB_VOLUME_RECONSTRUCTION_GLSL
#define LIB_VOLUME_RECONSTRUCTION_GLSL
// Neighbour depths reject volume samples from the other side of a foreground
// silhouette. No temporal history is needed, so captures remain deterministic.
vec4 upsampleClouds(vec2 uv, float distance) {
    vec3 ray = getCloudRayWorld(uv);
    float entry;
    float exit;
    if (isEyeInWater == 1 || (!airScatteringEnabled() && !localAtmosphereEnabled()
        && !cloudRayInterval(cameraPosition, ray, distance, entry, exit))) {
        return vec4(0.0);
    }
    vec2 size = volumeSize();
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    vec4 sum = vec4(0.0);
    float total = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 sampleUv = clamp((base + vec2(float(x), float(y)) + 0.5) / size,
                                  0.5 / size, 1.0 - 0.5 / size);
            float depth = texture2D(depthtex1, sampleUv).r;
            float neighbourDistance = depth < 0.999999 ? length(screenToView(sampleUv, depth)) : CLOUD_DISTANCE;
            float surface = readWaterSurface(colortex5, colortex1, sampleUv).a;
            if (surface > 0.001) {
                neighbourDistance = min(neighbourDistance, length(waterSurfacePosition(sampleUv, surface)));
            }
            float spatial = (x == 0 ? 1.0 - fraction.x : fraction.x)
                          * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = spatial * exp(-abs(neighbourDistance - distance) / max(distance * 0.10, 0.5));
            sum += texture2D(colortex4, sampleUv * size / vec2(viewWidth, viewHeight)) * weight;
            total += weight;
        }
    }
    return total > 0.00001 ? sum / total : vec4(0.0);
}

#endif
