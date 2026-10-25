/* Water samples a complete reflected-camera image. Waves perturb its UVs by
 * a bounded image-space displacement; no iterative depth rejection can turn a
 * leaf silhouette into a sky fallback. The image includes real background.
 */
#ifndef SIMPLE_WORLD_REFLECTION_PLANAR_GLSL
#define SIMPLE_WORLD_REFLECTION_PLANAR_GLSL
#include "/lib/world/planar.glsl"
#include "/lib/world/reflection_query.glsl"
#include "/lib/material_environment.glsl"

vec4 worldPlanarColour(vec2 uv, float roughness) {
    ivec4 field = worldRegion(WORLD_REGION_PLANAR_RADIANCE);
    vec2 size = vec2(textureSize(colortex6, 0));
    vec2 bounded = clamp(uv, 0.5 / vec2(field.zw), 1.0 - 0.5 / vec2(field.zw));
    float radius = roughness * 1.5;
    vec4 sum = vec4(0.0);
    for (int x = -1; x <= 1; x += 2) {
        for (int y = -1; y <= 1; y += 2) {
            vec2 samplePixel = clamp(bounded * vec2(field.zw) + vec2(x, y) * radius,
                vec2(0.5), vec2(field.zw) - 0.5);
            sum += textureLod(colortex6, (vec2(field.xy) + samplePixel) / size, 0.0);
        }
    }
    return sum * 0.25;
}

vec4 worldPlanarReflection(sampler2D scene, sampler2D depths, vec3 origin,
    vec3 direction, float roughness, float maximum, out float distance) {
    distance = 0.0;
    if (!worldPlanarValid(colortex6, frameCounter, false)) return vec4(0.0);
    float height = worldPlanarHeight(colortex6, false);
    vec3 relative = (gbufferModelViewInverse * vec4(origin, 1.0)).xyz;
    if (abs(relative.y + cameraPosition.y - height) > 0.20) return vec4(0.0);
    vec3 mirrored = relative;
    mirrored.y = 2.0 * (height - cameraPosition.y) - mirrored.y;
    vec3 virtualOrigin = (gbufferModelView * vec4(mirrored, 1.0)).xyz;
    mat4 projection = gbufferPreviousProjection;
    vec4 clip = projection * vec4(virtualOrigin, 1.0);
    vec2 base = clip.xy / clip.w * 0.5 * WORLD_PLANAR_SCALE + 0.5;
    vec2 uv = base;
    float depth = texelFetch(shadowtex0, worldPlanarAtlasPixel(base), 0).r;
    vec4 view = inverse(projection) * vec4(worldPlanarMainUv(base) * 2.0 - 1.0,
        depth * 2.0 - 1.0, 1.0);
    vec3 background = view.xyz / view.w;
    float range = depth < 0.999999 ? length(background - virtualOrigin) : min(maximum, 32.0);
    vec3 ray = normalize(mat3(gbufferModelViewInverse) * direction);
    ray.y = -ray.y;
    ray = normalize(mat3(gbufferModelView) * ray);
    clip = projection * vec4(virtualOrigin + ray * max(range, 0.1), 1.0);
    if (clip.w > 0.0) {
        vec2 displaced = clip.xy / clip.w * 0.5 * WORLD_PLANAR_SCALE + 0.5;
        vec2 offset = displaced - base;
        float extent = length(offset * vec2(WORLD_CAPTURE_PLANAR.zw));
        float limit = 10.0 * min(viewWidth, viewHeight) / 1080.0
            * float(WORLD_CAPTURE_PLANAR.w) / max(viewHeight, 1.0);
        offset *= limit / max(limit + extent, 0.00001);
        uv += offset;
    }
    vec4 reflected = worldPlanarColour(uv, roughness);
    WorldSample receiver = worldReadCell(colortex6, worldPosition(relative, cameraPosition), false);
    float sky = receiver.state == WORLD_WATER ? reflectionSkyLightWeight(receiver.light.y)
        : clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
    // Geometry is never dimmed by a sky-exposure heuristic. Only the actual
    // background portion of a filtered mirror texel receives that bound.
    reflected.rgb *= mix(sky, 1.0, clamp(reflected.a, 0.0, 1.0));
    distance = range;
    return vec4(reflected.rgb, 1.0);
}
#endif
