/* Opaque reflection radiance is straight linear HDR at mip zero. Filtering
 * must validate each texel before reading colour; a filtered colour lookup can
 * already contain sky/foreground pixels that a later depth test cannot remove.
 */
#ifndef LIB_REFLECTION_SOURCE_GLSL
#define LIB_REFLECTION_SOURCE_GLSL
#include "space.glsl"
#ifdef WORLD_GPU_BACKEND
ivec2 reflectionSourceTexel(sampler2D field, vec2 uv) {
    vec2 size = vec2(textureSize(field, 0));
    return ivec2(clamp(floor(uv * size), vec2(0.0), size - 1.0));
}
#define reflectionSourceRead(field, uv) texelFetch(field, reflectionSourceTexel(field, uv), 0)
#else
// The GLSL 120 path has no colour mip chain; exact centres still read level 0.
#define reflectionSourceRead(field, uv) texture2D(field, uv)
#endif

vec2 reflectionSourcePixel(vec2 uv) {
    vec2 size = vec2(viewWidth, viewHeight);
    return clamp(floor(uv * size), vec2(0.0), size - 1.0);
}

vec3 reflectionSourcePoint(sampler2D depths, vec2 pixel) {
    vec2 uv = (pixel + 0.5) / vec2(viewWidth, viewHeight);
    float depth = reflectionSourceRead(depths, uv).r;
    return depth < 0.999999 ? screenToView(uv, depth) : vec3(0.0, 0.0, -1e6);
}

// Only neighbours belonging to the hit plane participate. At one-pixel leaves
// or silhouettes there is no reliable plane, so the exact hit texel is retained.
vec3 reflectionSourceRadiance(sampler2D scene, sampler2D depths, vec2 uv) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 centrePixel = reflectionSourcePixel(uv);
    vec2 centreUv = (centrePixel + 0.5) / size;
    vec3 centre = reflectionSourcePoint(depths, centrePixel);
    vec3 left = reflectionSourcePoint(depths, max(centrePixel - vec2(1.0, 0.0), vec2(0.0)));
    vec3 right = reflectionSourcePoint(depths, min(centrePixel + vec2(1.0, 0.0), size - 1.0));
    vec3 down = reflectionSourcePoint(depths, max(centrePixel - vec2(0.0, 1.0), vec2(0.0)));
    vec3 up = reflectionSourcePoint(depths, min(centrePixel + vec2(0.0, 1.0), size - 1.0));
    vec3 dx = abs(left.z - centre.z) < abs(right.z - centre.z) ? centre - left : right - centre;
    vec3 dy = abs(down.z - centre.z) < abs(up.z - centre.z) ? centre - down : up - centre;
    vec3 plane = cross(dx, dy);
    float scale = length(plane);
    float continuity = max(0.04, -centre.z * 0.015);
    bool valid = scale > 1e-10 && abs(dx.z) < continuity && abs(dy.z) < continuity;
    if (!valid) return reflectionSourceRead(scene, centreUv).rgb;
    plane /= scale;
    float tolerance = max(0.002, min(length(dx), length(dy)) * 0.12);
    vec2 pixel = uv * size - 0.5;
    vec2 first = floor(pixel);
    vec2 fraction = fract(pixel);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(first + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            vec2 sampleUv = (cell + 0.5) / size;
            float depth = reflectionSourceRead(depths, sampleUv).r;
            if (depth >= 0.999999) continue;
            vec3 point = screenToView(sampleUv, depth);
            if (abs(dot(plane, point - centre)) > tolerance) continue;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y);
            // RGB is not premultiplied by opaque alpha. Dividing it by coverage
            // brightens cutout edges; mip levels also mix unrelated geometry.
            sum += reflectionSourceRead(scene, sampleUv).rgb * weight;
            total += weight;
        }
    }
    return total > 0.00001 ? sum / total : reflectionSourceRead(scene, centreUv).rgb;
}
// Reconstruct radiance on the hit surface. The image footprint is not a set of
// reflected directions: a sky texel beside a wall does not prove the reflection
// ray missed the wall. Reject that texel without reducing the confirmed hit's
// coverage. Roughness integration traces directions separately.
vec4 reflectionSourceFiltered(sampler2D scene, sampler2D depths, vec2 uv,
    float hitDepth, float distance, float roughness) {
    float radius = roughness * roughness * min(viewWidth, viewHeight) * 0.03
        * clamp(distance / max(hitDepth, 0.01), 0.0, 2.0);
    vec3 centre = reflectionSourceRadiance(scene, depths, uv);
    if (radius < 0.25) return vec4(centre, 1.0);
    vec3 sum = centre;
    float covered = 1.0;
    vec2 size = vec2(viewWidth, viewHeight);
    for (int x = -1; x <= 1; x += 2) {
        for (int y = -1; y <= 1; y += 2) {
            vec2 tap = clamp(uv + vec2(float(x), float(y)) * radius / size,
                0.5 / size, 1.0 - 0.5 / size);
            vec2 pixel = (reflectionSourcePixel(tap) + 0.5) / size;
            float depth = reflectionSourceRead(depths, pixel).r;
            if (depth >= 0.999999) continue;
            float z = -screenToView(pixel, depth).z;
            if (abs(z - hitDepth) > max(0.10, hitDepth * 0.06)) continue;
            sum += reflectionSourceRead(scene, pixel).rgb;
            covered += 1.0;
        }
    }
    return vec4(sum / covered, 1.0);
}

#endif
