/*
 * Single-scattering volumetric cloud integration with approximate multiple
 * scattering. Main sky clouds render at half resolution; reflections use fewer
 * samples. Empty regions skip lighting and dense rays terminate early.
 */
#ifndef LIB_CLOUDS_GLSL
#define LIB_CLOUDS_GLSL

#include "/lib/cloud_density.glsl"
#include "/lib/lighting.glsl"
#include "/lib/sky.glsl"

vec3 getCloudRayWorld(vec2 uv) {
    return skyViewDirection(uv);
}

bool cloudRayInterval(vec3 origin, vec3 ray, float limit, out float entry, out float exit) {
    vec2 altitude = cloudAltitudeBounds();
    entry = 0.0;
    exit = min(limit, CLOUD_DISTANCE);
    if (abs(ray.y) < 0.00001) {
        return origin.y > altitude.x && origin.y < altitude.y && exit > 0.0;
    }
    float lower = (altitude.x - origin.y) / ray.y;
    float upper = (altitude.y - origin.y) / ray.y;
    entry = max(min(lower, upper), 0.0);
    exit = min(max(lower, upper), exit);
    return exit > entry;
}

float cloudPhase(float cosine, float g) {
    return (1.0 - g * g) / (4.0 * PI * pow(max(1.0 + g * g - 2.0 * g * cosine, 0.01), 1.5));
}

// Increasing light steps probe both the local shell and the surrounding mass.
float cloudLightOpticalDepth(vec3 position, vec3 direction, int samples) {
    float sum = 0.0;
    float previous = 0.0;
    for (int index = 0; index < 5; index++) {
        if (index >= samples) {
            break;
        }
        float u = float(index + 1) / float(samples);
        float next = CLOUD_THICKNESS * 1.4 * u * u;
        float interval = next - previous;
        sum += cloudDensity(position + direction * (previous + next) * 0.5, false) * interval;
        previous = next;
    }
    return sum * 0.04 * CLOUD_OPACITY;
}

vec4 traceVolumetricCloudsFrom(vec3 origin, vec3 ray, float limit, bool reflection) {
    if (CLOUD_OPACITY <= 0.0 || CLOUD_COVERAGE <= 0.0) {
        return vec4(0.0);
    }
    float entry;
    float exit;
    if (!cloudRayInterval(origin, ray, limit, entry, exit)) {
        return vec4(0.0);
    }
    int samples = CLOUD_QUALITY == 0 ? 24 : (CLOUD_QUALITY == 1 ? 40 : 64);
    int lightSamples = CLOUD_QUALITY == 0 ? 2 : (CLOUD_QUALITY == 1 ? 3 : 5);
    if (reflection) {
        samples = 16;
        lightSamples = 2;
    }
    vec3 lightDirection = skyDaylight() > 0.5 ? skySunDirection() : skyMoonDirection();
    vec3 direct = getSunLightColor() + getMoonLightColor();
    float cosine = dot(ray, lightDirection);
    float phase = cloudPhase(cosine, 0.62) * 0.8 + cloudPhase(cosine, -0.20) * 0.2;
    float day = skyDaylight();
    vec3 ambient = mix(vec3(0.003, 0.0038, 0.005), vec3(0.22, 0.27, 0.33), day);
    ambient *= mix(CLOUD_NIGHT_BRIGHTNESS * (0.2 + 0.8 * lunarIlluminatedFraction()), 1.0, day);
    vec3 atmosphere = skyAtmosphereRadiance(ray);
    float jitter = cloudCellHash(floor(gl_FragCoord.xy));
    vec3 accumulated = vec3(0.0);
    float transmission = 1.0;
    float previous = entry;
    for (int index = 0; index < 64; index++) {
        if (index >= samples || transmission < 0.015) {
            break;
        }
        float u = float(index + 1) / float(samples);
        float next = mix(entry, exit, u * u);
        float stepLength = next - previous;
        vec3 position = origin + ray * mix(previous, next, 0.25 + jitter * 0.5);
        float height;
        float density = cloudDensityWithHeight(position, stepLength < 45.0, height);
        previous = next;
        if (density <= 0.0001) {
            continue;
        }
        float opticalDepth = cloudLightOpticalDepth(position, lightDirection, lightSamples);
        float lightTransmission = exp(-opticalDepth);
        // A second, softer term and a powder approximation preserve luminous
        // shells and soften the contrast inside optically thick cloud masses.
        float multiple = exp(-opticalDepth * 0.28) * 0.22;
        float powder = 1.0 - exp(-density * 8.0);
        vec3 source = ambient * mix(0.40, 1.0, height)
                    + direct * (lightTransmission * phase * 5.0 + multiple) * mix(0.65, 1.0, powder);
        float aerial = exp(-length(position - origin) * mix(0.00016, 0.00035, rainStrength));
        source = mix(atmosphere, source * CLOUD_BRIGHTNESS, aerial);
        float segmentTransmission = exp(-density * stepLength * 0.04 * CLOUD_OPACITY);
        accumulated += transmission * (1.0 - segmentTransmission) * source;
        transmission *= segmentTransmission;
    }
    return vec4(accumulated, 1.0 - transmission);
}

vec4 traceVolumetricClouds(vec3 ray, float limit) {
    if (isEyeInWater == 1) {
        return vec4(0.0);
    }
    return traceVolumetricCloudsFrom(cameraPosition, ray, limit, false);
}

#endif
