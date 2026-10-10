/*
 * Continuous cloud density and inexpensive projected cloud shadows.
 * The tiled 64-cubed periodic field is baked by tools/build_sky_assets.py.
 * Weather changes cloud coverage and vertical profile; three Worley bands erode
 * the boundary without introducing a block lattice or per-frame shape popping.
 */
#ifndef LIB_CLOUD_DENSITY_GLSL
#define LIB_CLOUD_DENSITY_GLSL

#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"
#include "sky_noise.glsl"

float cloudCellHash(vec2 cell) {
    vec3 value = fract(vec3(cell.x, cell.y, cell.x) * 0.1031);
    value += dot(value, value.yzx + 33.33);
    return fract((value.x + value.y) * value.z);
}

float cloudWeatherNoise(vec2 coordinate) {
    vec2 cell = floor(coordinate);
    vec2 weight = fract(coordinate);
    weight = weight * weight * (3.0 - 2.0 * weight);
    float lower = mix(cloudCellHash(cell), cloudCellHash(cell + vec2(1.0, 0.0)), weight.x);
    float upper = mix(cloudCellHash(cell + vec2(0.0, 1.0)), cloudCellHash(cell + vec2(1.0)), weight.x);
    return mix(lower, upper, weight.y);
}

vec4 cloudVolumeNoise(vec3 coordinate) {
    vec3 p = fract(coordinate) * 64.0;
    float slice = floor(p.z);
    float nextSlice = mod(slice + 1.0, 64.0);
    vec2 first = vec2(mod(slice, 8.0), floor(slice / 8.0)) * 66.0;
    vec2 second = vec2(mod(nextSlice, 8.0), floor(nextSlice / 8.0)) * 66.0;
    vec2 inside = p.xy + 1.5;
    vec4 lower = texture2D(noisetex, (first + inside) / 1024.0);
    vec4 upper = texture2D(noisetex, (second + inside) / 1024.0);
    return mix(lower, upper, fract(p.z));
}

vec2 cloudWindOffset() {
    return frameTimeCounter * CLOUD_SPEED * vec2(1.0, 0.21);
}

// Broad-phase bounds include every possible local base and cloud thickness.
// Both view rays and shadow rays must include these bounds to avoid clipping
// elevated clouds or prematurely rejecting the lower cloud groups.
vec2 cloudAltitudeBounds() {
    return vec2(CLOUD_HEIGHT - CLOUD_THICKNESS * 0.65,
                CLOUD_HEIGHT + CLOUD_THICKNESS * 1.90);
}

// Regional and cloud-group variations move with the weather field. Thickness
// varies independently, so the layer has uneven bottoms as well as uneven tops.
vec2 cloudColumnBounds(vec2 position, float type) {
    float groupHeight = cloudWeatherNoise(position / (CLOUD_SIZE * 0.60)
                                          + vec2(127.0, 59.0));
    float heightField = mix(type, groupHeight, 0.40);
    float offset = (heightField * 2.0 - 1.0) * CLOUD_THICKNESS * 0.65;
    float bottom = CLOUD_HEIGHT + offset;
    float thickness = CLOUD_THICKNESS * mix(0.75, 1.25, type);
    return vec2(bottom, bottom + thickness);
}

// Return local relative height with density; cloud lighting can reuse it without
// repeating the weather samples or treating every cloud as equally elevated.
float cloudDensityWithHeight(vec3 world, bool erosion, out float height) {
    height = 0.0;
    vec2 altitude = cloudAltitudeBounds();
    if (world.y <= altitude.x || world.y >= altitude.y
        || CLOUD_COVERAGE <= 0.0 || CLOUD_OPACITY <= 0.0) {
        return 0.0;
    }
    vec2 horizontal = world.xz - cloudWindOffset();
    float type = cloudWeatherNoise(horizontal / (CLOUD_SIZE * 4.0) + 43.0);
    vec2 column = cloudColumnBounds(horizontal, type);
    height = (world.y - column.x) / (column.y - column.x);
    if (height <= 0.0 || height >= 1.0) {
        return 0.0;
    }
    vec3 position = vec3(horizontal.x, world.y - column.x, horizontal.y);
    float weather = cloudWeatherNoise(position.xz / (CLOUD_SIZE * 2.5)) * 0.65
                  + cloudWeatherNoise(position.xz / (CLOUD_SIZE * 0.85) + 19.0) * 0.35;
    float coverage = clamp(CLOUD_COVERAGE + (weather - 0.5) * 0.36 + rainStrength * 0.22, 0.02, 0.96);
    float profile = smoothstep(0.0, 0.08, height)
                  * (1.0 - smoothstep(mix(0.42, 0.70, type), 1.0, height));
    vec4 noise = cloudVolumeNoise(position / CLOUD_SIZE);
    float shape = clamp((noise.r - (1.0 - coverage)) / 0.20, 0.0, 1.0) * profile;
    if (erosion && shape > 0.0) {
        float detail = noise.g * 0.5 + noise.b * 0.3 + noise.a * 0.2;
        shape = max(shape - (1.0 - detail) * 0.18 * (1.0 - shape), 0.0);
    }
    return shape * CLOUD_DENSITY;
}

float cloudDensity(vec3 world, bool erosion) {
    float height;
    return cloudDensityWithHeight(world, erosion, height);
}

// Geometry receives only a soft direct-light shadow. Local lights and sky
// scattering retain their own contributions. Five samples cover the wider
// altitude range without skipping the narrower, displaced cloud groups.
float cloudProjectedShadow(vec3 world, vec3 lightDirection) {
    vec2 altitude = cloudAltitudeBounds();
    if (CLOUD_SHADOW_STRENGTH <= 0.0 || lightDirection.y <= 0.04 || world.y >= altitude.y) {
        return 1.0;
    }
    float entry = max((altitude.x - world.y) / lightDirection.y, 0.0);
    float exit = (altitude.y - world.y) / lightDirection.y;
    float stepLength = (exit - entry) / 5.0;
    float density = 0.0;
    for (int index = 0; index < 5; index++) {
        vec3 samplePosition = world + lightDirection * (entry + (float(index) + 0.5) * stepLength);
        density += cloudDensity(samplePosition, false);
    }
    float transmission = exp(-density * stepLength * 0.04 * CLOUD_OPACITY);
    return mix(1.0, transmission, CLOUD_SHADOW_STRENGTH);
}

#endif
