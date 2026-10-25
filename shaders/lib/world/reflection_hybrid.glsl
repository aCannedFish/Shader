/* World geometry determines reflection correspondence. Screen colour is used
 * only when its actual depth agrees with that same surface; an unrelated leaf
 * silhouette cannot provide sky/foreground colour to a wall behind it.
 */
#ifndef SIMPLE_WORLD_REFLECTION_HYBRID_GLSL
#define SIMPLE_WORLD_REFLECTION_HYBRID_GLSL
#include "/lib/world/reflection_query.glsl"
#include "/lib/reflection_source.glsl"
#include "/lib/screen_reflection.glsl"

vec4 worldHybridReflection(sampler2D scene, sampler2D depths, vec3 origin,
    vec3 direction, float minimum, float maximum, int screenSteps, vec4 clipPlane,
    out float distance) {
    bool thin;
    vec4 screen = traceScreenReflection(depths, origin, direction, minimum,
        maximum, screenSteps, clipPlane, thin);
    vec3 relative = (gbufferModelViewInverse * vec4(origin, 1.0)).xyz;
    vec3 ray = normalize(mat3(gbufferModelViewInverse) * direction);
    WorldHit world = worldTraceReflection(worldPosition(relative, cameraPosition),
        ray, minimum, maximum, WORLD_REFLECTION_STEPS);
    bool candidate = world.coverage > 0.0 && world.confidence > 0.0;
    distance = 0.0;
    if (candidate) {
        vec3 position = (gbufferModelView * vec4(world.position, 1.0)).xyz;
        if (dot(clipPlane.xyz, position) + clipPlane.w >= 0.0) {
            vec4 clip = gbufferProjection * vec4(position, 1.0);
            vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
            if (clip.w > 0.0 && all(greaterThan(uv, vec2(0.0)))
                && all(lessThan(uv, vec2(1.0)))) {
                vec2 pixel = reflectionPixelUv(uv);
                float depth = textureLod(depths, pixel, 0.0).r;
                vec3 visible = screenToView(pixel, depth);
                float tolerance = max(0.015, length(position) / max(viewHeight, 1.0) * 0.65);
                // The camera may see foreground foliage while the reflected ray
                // hits the wall. Those two different surfaces must not share RGB.
                if (depth < 0.999999 && abs(visible.z - position.z) <= tolerance
                    && (!thin || abs(screen.z - world.distance) < tolerance)) {
                    distance = world.distance;
                    return vec4(reflectionSourceRadiance(scene, depths, uv) * world.transmission, 1.0);
                }
            }
            distance = world.distance;
            return vec4(world.radiance, 1.0);
        }
    }
    if (screen.a > 0.0 && !thin) {
        distance = screen.z;
        return vec4(reflectionSourceRadiance(scene, depths, screen.xy), 1.0);
    }
    // A one-pixel silhouette is not enough to invent a hidden face. Unknown
    // paths remain unconfirmed instead of borrowing a blue/black outline.
    return vec4(0.0);
}
#endif
