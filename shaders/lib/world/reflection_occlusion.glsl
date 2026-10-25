/* World geometry supplements screen reflection only after raster coverage
 * validation. A front-facing leaf reported opaque by an approximate query may
 * not replace a main-view pixel that actually shows the background through it.
 */
#ifndef SIMPLE_WORLD_REFLECTION_OCCLUSION_GLSL
#define SIMPLE_WORLD_REFLECTION_OCCLUSION_GLSL
#include "/lib/world/reflection_query.glsl"
#include "/lib/material_environment.glsl"
#include "/lib/reflection_source.glsl"

const float REFLECTION_OCCLUSION_RANGE = 128.0;

vec3 reflectionHiddenAmbient(vec3 direction, vec2 lightmap) {
    return materialAmbientEnvironment(-direction, lightmap) * 0.3;
}

bool reflectionRasterCoverage(sampler2D scene, sampler2D depths, WorldHit hit,
    out bool visible, out vec3 colour) {
    visible = false;
    colour = hit.radiance;
    vec3 position = (gbufferModelView * vec4(hit.position, 1.0)).xyz;
    vec4 clip = gbufferProjection * vec4(position, 1.0);
    vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
    if (clip.w <= 0.0 || any(lessThan(uv, vec2(0.0)))
        || any(greaterThan(uv, vec2(1.0)))) return true;
    ivec2 pixel = clamp(ivec2(floor(uv * vec2(viewWidth, viewHeight))),
        ivec2(0), ivec2(viewWidth, viewHeight) - 1);
    float depth = texelFetch(depths, pixel, 0).r;
    bool facesCamera = dot(hit.normal, -hit.position) > 0.0;
    if (depth >= 0.999999) return !facesCamera;
    vec2 pixelUv = (vec2(pixel) + 0.5) / vec2(viewWidth, viewHeight);
    vec3 actual = screenToView(pixelUv, depth);
    float tolerance = max(0.015, -position.z * 2.0
        * abs(gbufferProjectionInverse[1][1]) / max(viewHeight, 1.0));
    // The current camera sees farther than this front-facing candidate: its
    // coverage contradicts the actual raster. Continue beyond that face.
    if (facesCamera && actual.z < position.z - tolerance) return false;
    if (abs(actual.z - position.z) <= tolerance) {
        visible = true;
        colour = reflectionSourceRadiance(scene, depths, uv) * hit.transmission;
    }
    return true;
}

vec4 reflectionOcclusionPlane(sampler2D scene, sampler2D depths, vec3 origin,
    vec3 direction, vec3 ambient, vec4 clipPlane, float maximum, out float hitDistance) {
    vec3 relative = (gbufferModelViewInverse * vec4(origin, 1.0)).xyz;
    vec3 worldDirection = normalize(mat3(gbufferModelViewInverse) * direction);
    WorldPosition start = worldPosition(relative, cameraPosition);
    float minimum = 0.001;
    hitDistance = 0.0;
    for (int layer = 0; layer < 4; layer++) {
        WorldHit hit = worldTraceReflection(start, worldDirection, minimum,
            min(maximum, REFLECTION_OCCLUSION_RANGE), WORLD_REFLECTION_STEPS);
        if (hit.coverage <= 0.0 || hit.confidence <= 0.0) return vec4(0.0);
        vec3 position = (gbufferModelView * vec4(hit.position, 1.0)).xyz;
        if (dot(clipPlane.xyz, position) + clipPlane.w < 0.0) {
            minimum = hit.distance + 0.002;
            continue;
        }
        bool visible;
        vec3 colour;
        if (!reflectionRasterCoverage(scene, depths, hit, visible, colour)) {
            minimum = hit.distance + 0.002;
            continue;
        }
        hitDistance = hit.distance;
        return vec4(colour, 1.0);
    }
    return vec4(0.0);
}

vec4 reflectionOcclusion(sampler2D scene, sampler2D depths, vec3 origin,
    vec3 direction, vec3 ambient, out float hitDistance) {
    return reflectionOcclusionPlane(scene, depths, origin, direction, ambient,
        vec4(0.0), far, hitDistance);
}

bool reflectionOcclusionCloser(vec4 occlusion, float worldDistance, float screenDistance) {
    return occlusion.a > 0.0 && (screenDistance <= 0.0
        || worldDistance + max(0.03, worldDistance * 0.002) < screenDistance);
}
#endif
