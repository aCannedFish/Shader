/* 镜头光学近似：太阳的遮挡感知光晕与轻度径向色差。
 * 光晕亮度只在亮部阶段的首个纹素计算一次，再通过附件 alpha 传递。
 */
#ifndef LIB_LENS_OPTICS_GLSL
#define LIB_LENS_OPTICS_GLSL
#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"
#include "space.glsl"

vec2 lensSunUv() {
    vec4 projected = gbufferProjection * vec4(normalize(sunPosition), 0.0);
    return projected.xy / max(projected.w, EPSILON) * 0.5 + 0.5;
}

// 九点覆盖太阳圆盘。深度拒绝实体遮挡，实际 HDR 亮度同时限制云层和浓雾中的光晕。
float lensSunVisibility(sampler2D scene, sampler2D depths) {
#if ENABLE_LENS_FLARE == 0 || SIMPLE_DIMENSION != 0
    return 0.0;
#else
    vec3 direction = normalize(sunPosition);
    vec3 world = mat3(gbufferModelViewInverse) * direction;
    vec2 center = lensSunUv();
    float edge = min(min(center.x, center.y), min(1.0 - center.x, 1.0 - center.y));
    if (LENS_FLARE_STRENGTH <= 0.0 || isEyeInWater != 0
        || direction.z >= -0.05 || world.y <= 0.0 || edge <= 0.0) {
        return 0.0;
    }
    vec3 right = normalize(cross(direction, vec3(0.0, 1.0, 0.0)));
    vec3 up = cross(right, direction);
    float sum = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec3 ray = direction + (right * float(x) + up * float(y))
                     * (0.075 * CELESTIAL_SIZE * 0.55);
            vec4 clip = gbufferProjection * vec4(ray, 0.0);
            vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
            if (all(greaterThan(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)))) {
                float sky = step(0.999999, texture2D(depths, uv).r);
                float bright = smoothstep(0.8, 2.5, luma(texture2D(scene, uv).rgb));
                sum += sky * bright;
            }
        }
    }
    return sum / 9.0 * smoothstep(0.0, 0.06, edge) * smoothstep(0.0, 0.06, world.y);
#endif
}

// 平滑、有限范围的镀膜鬼影，避免硬圆边与整屏雾状增亮。
float lensGhost(vec2 uv, vec2 center, float radius) {
    vec2 offset = (uv - center) * vec2(aspectRatio, 1.0);
    float weight = max(1.0 - dot(offset, offset) / (radius * radius), 0.0);
    return weight * weight * weight;
}

vec3 lensFlare(vec2 uv, float visibility) {
#if ENABLE_LENS_FLARE == 0
    return vec3(0.0);
#else
    if (visibility <= 0.0 || LENS_FLARE_STRENGTH <= 0.0) {
        return vec3(0.0);
    }
    vec2 source = lensSunUv();
    vec2 axis = source - 0.5;
    float separation = smoothstep(0.0, 0.10, length(axis));
    vec3 ghosts = vec3(0.45, 0.75, 0.65) * 1.00
                * lensGhost(uv, vec2(0.5) - axis * 0.45, 0.045);
    ghosts += vec3(0.90, 0.55, 0.30) * 0.40
            * lensGhost(uv, vec2(0.5) - axis * 0.95, 0.075);
    vec2 offset = (uv - source) * vec2(aspectRatio, 1.0);
    vec2 line = max(vec2(1.0) - abs(offset) / 0.0015, vec2(0.0));
    float glint = dot(line, line) / (1.0 + dot(offset, offset) * 400.0);
    vec3 tint = mix(vec3(1.0, 0.65, 0.32), vec3(1.0, 0.95, 0.85),
                    smoothstep(0.05, 0.60, (mat3(gbufferModelViewInverse)
                        * normalize(sunPosition)).y));
    return (ghosts * separation + tint * glint * 0.12)
         * visibility * LENS_FLARE_STRENGTH;
#endif
}

// 中心保持清晰，向角落逐渐增加红蓝通道的相反偏移；边界采样始终留在图内。
vec3 sampleChromaticScene(sampler2D scene, vec2 uv) {
    vec3 color = texture2D(scene, uv).rgb;
#if ENABLE_CHROMATIC_ABERRATION == 1
    if (CHROMATIC_ABERRATION_STRENGTH > 0.0) {
        vec2 radial = (uv - 0.5) * vec2(aspectRatio, 1.0);
        float squared = dot(radial, radial);
        float edge = squared / (0.25 * (aspectRatio * aspectRatio + 1.0));
        vec2 pixels = radial / max(sqrt(squared), EPSILON) * edge * edge
                    * CHROMATIC_ABERRATION_STRENGTH * min(viewWidth, viewHeight) / 1080.0;
        vec2 size = vec2(viewWidth, viewHeight);
        vec2 offset = pixels / size;
        color.r = texture2D(scene, clamp(uv + offset, 0.5 / size, 1.0 - 0.5 / size)).r;
        color.b = texture2D(scene, clamp(uv - offset, 0.5 / size, 1.0 - 0.5 / size)).b;
    }
#endif
    return color;
}
#endif
