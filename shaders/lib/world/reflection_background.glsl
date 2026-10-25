/* Low-confidence reconstruction uses a real opaque frame pixel behind the
 * failed foreground query. It never reuses an old depth as an invented plane.
 */
#ifndef SIMPLE_WORLD_REFLECTION_BACKGROUND_GLSL
#define SIMPLE_WORLD_REFLECTION_BACKGROUND_GLSL
#include "/lib/world/storage.glsl"
#include "/lib/world/layout.glsl"
#include "/lib/space.glsl"

vec4 reflectionKnownBackground(sampler2D scene, sampler2D depths, vec2 foregroundUv,
    float foregroundDepth, vec3 origin, vec3 direction, float maximum, vec4 clipPlane) {
    ivec4 field = worldRegion(WORLD_REGION_REFLECTION_BACKGROUND);
    ivec2 centre = ivec2(floor(foregroundUv * vec2(field.zw)));
    vec4 result = vec4(0.0);
    float nearest = 1e20;
    vec2 size = vec2(viewWidth, viewHeight);
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            ivec2 cell = clamp(centre + ivec2(x, y), ivec2(0), field.zw - 1);
            ivec4 encoded = ivec4(round(texelFetch(colortex6, field.xy + cell, 0)));
            if (encoded.w < 256) continue;
            ivec2 pixel = ivec2(encoded.x + encoded.y * 256, encoded.z + (encoded.w - 256) * 256);
            if (any(greaterThanEqual(pixel, ivec2(size)))) continue;
            float flags = texelFetch(scene, pixel, 0).a;
            if (flags < 0.5 || flags > 1.5) continue;
            vec2 uv = (vec2(pixel) + 0.5) / size;
            float depth = texelFetch(depths, pixel, 0).r;
            if (depth >= 0.999999) continue;
            vec3 point = screenToView(uv, depth);
            if (-point.z <= foregroundDepth + max(0.02, foregroundDepth * 0.002)) continue;
            if (dot(clipPlane.xyz, point) + clipPlane.w < 0.0) continue;
            float along = dot(point - origin, direction);
            if (along <= 0.0 || along >= maximum) continue;
            float error = length(point - origin - direction * along);
            float footprint = max(0.005, -point.z * 2.0 * abs(gbufferProjectionInverse[1][1])
                / max(viewHeight, 1.0));
            float limit = 3.0 * max(size.x / float(field.z), size.y / float(field.w));
            vec4 rayClip = gbufferProjection * vec4(origin + direction * along, 1.0);
            vec2 rayUv = rayClip.xy / rayClip.w * 0.5 + 0.5;
            vec2 outside = max(abs(rayUv - 0.5) - 0.5, vec2(0.0));
            float edgeAllowance = length(outside * size) * footprint / 2.0;
            float score = error / max(footprint, edgeAllowance);
            if (score < nearest && score < limit) {
                nearest = score;
                result = vec4(uv, along, 1.0);
            }
        }
    }
    return result;
}
#endif
