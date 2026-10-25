/* Adaptive screen reflection inspired by the refinement strategy used in BSL,
 * Complementary and Sildur. A candidate is refined by shortening the travelled
 * segment; thin alpha-tested surfaces need no unreliable depth-plane normal.
 */
#ifndef LIB_SCREEN_REFLECTION_ADAPTIVE_GLSL
#define LIB_SCREEN_REFLECTION_ADAPTIVE_GLSL
#include "space.glsl"
#include "screen_reflection.glsl"

struct ScreenReflectionHit {
    vec2 uv;
    float distance;
    float coverage;
    float confidence;
    bool refined;
};

ScreenReflectionHit screenReflectionHit(vec4 hit, float confidence, bool refined) {
    return ScreenReflectionHit(hit.xy, hit.z, hit.a, confidence, refined);
}

// Continuous opaque depth can reject a back-facing plane. A ray travelling up
// from water cannot hit the top of a sand step from underneath. Cutout texels
// and silhouettes with no reliable tangent retain their raster coverage.
bool reflectionSurfaceFacesRay(sampler2D scene, sampler2D depths, vec2 uv, vec3 direction) {
    if (texture2D(scene, uv).a > 2.5) return true;
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 centre = screenToView(uv, texture2D(depths, uv).r);
    vec3 left = reflectionNeighbour(depths, clamp(uv - vec2(texel.x, 0.0), texel * 0.5, 1.0 - texel * 0.5));
    vec3 right = reflectionNeighbour(depths, clamp(uv + vec2(texel.x, 0.0), texel * 0.5, 1.0 - texel * 0.5));
    vec3 down = reflectionNeighbour(depths, clamp(uv - vec2(0.0, texel.y), texel * 0.5, 1.0 - texel * 0.5));
    vec3 up = reflectionNeighbour(depths, clamp(uv + vec2(0.0, texel.y), texel * 0.5, 1.0 - texel * 0.5));
    vec3 dx = abs(left.z - centre.z) < abs(right.z - centre.z) ? centre - left : right - centre;
    vec3 dy = abs(down.z - centre.z) < abs(up.z - centre.z) ? centre - down : up - centre;
    vec3 plane = cross(dx, dy);
    float magnitude = length(plane);
    float continuity = max(0.04, -centre.z * 0.015);
    if (magnitude <= 1e-10 || abs(dx.z) > continuity || abs(dy.z) > continuity) return true;
    plane /= magnitude;
    plane *= dot(plane, -centre) >= 0.0 ? 1.0 : -1.0;
    return dot(plane, direction) < 0.001;
}

ScreenReflectionHit traceAdaptiveReflectionDetailed(sampler2D scene, sampler2D depths, vec3 origin, vec3 direction,
    float minimum, float maximum, int budget, vec4 clipPlane) {
    float stride = max(0.005, length(origin) / max(viewHeight, 1.0) * 0.25);
    float distance = minimum;
    int refinements = 0;
    vec4 closest = vec4(0.0);
    float closestError = 1e20;
    vec4 candidate = vec4(0.0);
    float candidateStride = 1e20;
    vec4 background = vec4(0.0);
    float backgroundError = 1e20;
    vec2 foregroundUv = vec2(0.0);
    float foregroundDepth = 0.0;
    float foregroundError = 1e20;
    for (int iteration = 0; iteration < 96; iteration++) {
        if (iteration >= budget || distance > maximum) break;
        float previous = distance;
        distance += stride;
        vec3 point = origin + direction * distance;
        vec4 clip = gbufferProjection * vec4(point, 1.0);
        if (clip.w <= near) break;
        vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
        vec2 outside = max(abs(uv - 0.5) - 0.5, vec2(0.0));
        if (max(outside.x, outside.y) > 0.10) break;
        vec2 size = vec2(viewWidth, viewHeight);
        vec2 unclampedUv = uv;
        uv = clamp(uv, 0.5 / size, 1.0 - 0.5 / size);
        vec2 pixel = (floor(uv * size) + 0.5) / size;
        float depth = texture2D(depths, pixel).r;
        if (depth < 0.999999) {
            vec3 surface = screenToView(pixel, depth);
            if (dot(clipPlane.xyz, surface) + clipPlane.w >= 0.0) {
                float error = length(point - surface);
                float cone = max(0.003, -surface.z * 2.0
                    * abs(gbufferProjectionInverse[1][1]) / max(viewHeight, 1.0));
                float along = dot(surface - origin, direction);
                float perpendicular = length(surface - origin - direction * along);
                if (along > minimum && along < maximum && perpendicular < cone * 1.5
                    && perpendicular < closestError && reflectionSurfaceFacesRay(scene, depths, pixel, direction)) {
                    closestError = perpendicular;
                    closest = vec4(pixel, along, 1.0);
                }
                // Retain a nearby opaque backing surface as a lower-confidence
                // reconstruction. This uses an actual frame pixel and depth;
                // it does not invent a hidden plane from an earlier sample.
                float flags = texture2D(scene, pixel).a;
                float edgeAllowance = length((unclampedUv - uv) * size)
                    * cone / 2.0;
                float normalizedError = perpendicular / max(cone, edgeAllowance);
                if (flags > 2.5 && along > minimum && along < maximum
                    && normalizedError < foregroundError) {
                    foregroundError = normalizedError;
                    foregroundUv = pixel;
                    foregroundDepth = -surface.z;
                }
                if (flags > 0.5 && flags < 1.5 && along > minimum && along < maximum
                    && normalizedError < 16.0 && normalizedError < backgroundError) {
                    background = vec4(pixel, along, 1.0);
                    backgroundError = normalizedError;
                }
                if (error < max(stride * 1.25, cone)
                    && reflectionSurfaceFacesRay(scene, depths, pixel, direction)) {
                    // A finite quality budget may end during refinement. Keep
                    // the last actual surface reached by the shrinking segment;
                    // exhausting iterations does not turn that surface into sky.
                    if (along > minimum && along < maximum && stride < candidateStride) {
                        candidate = vec4(pixel, along, 1.0);
                        candidateStride = stride;
                    }
                    if (refinements >= 4 || stride < cone * 0.25) {
                        vec2 edge = min(uv, vec2(1.0) - uv);
                        float confidence = smoothstep(0.0, 0.02, min(edge.x, edge.y));
                        return screenReflectionHit(vec4(pixel, max(along, minimum), 1.0), confidence, true);
                    }
                    refinements++;
                    distance = previous;
                    stride *= 0.22;
                    continue;
                }
            }
        }
        stride *= 1.8;
    }
    // A geometrically supported pixel remains usable when the final step ran
    // out of budget. It does not become sky merely because its neighbours are
    // leaves, a thin fence, or background at another depth.
    if (closest.a > 0.0) return screenReflectionHit(closest, 0.7, false);
    if (candidate.a > 0.0) return screenReflectionHit(candidate, 0.4, false);
    if (foregroundDepth > 0.0 && background.a > 0.0) {
        return screenReflectionHit(background, 1.0 / (1.0 + backgroundError), false);
    }
    // WORLD_BACKGROUND_RECONSTRUCTION
    return screenReflectionHit(vec4(0.0), 0.0, false);
}

// Existing consumers use geometric coverage for colour composition. Confidence
// is reserved for validation/history and must not reveal sky inside a known hit.
vec4 traceAdaptiveReflection(sampler2D scene, sampler2D depths, vec3 origin, vec3 direction,
    float minimum, float maximum, int budget, vec4 clipPlane) {
    ScreenReflectionHit hit = traceAdaptiveReflectionDetailed(scene, depths, origin,
        direction, minimum, maximum, budget, clipPlane);
    return vec4(hit.uv, hit.distance, hit.coverage);
}
#endif
