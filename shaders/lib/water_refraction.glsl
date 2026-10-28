/* 空气到水的折射。按 Snell 方向与水底局部平面求交，再用深度修正三次。
 * 屏幕边缘及岸上前景逐渐收回偏移，避免把岸边物体拉进水中。
 */
#ifndef LIB_WATER_REFRACTION_GLSL
#define LIB_WATER_REFRACTION_GLSL
#include "water.glsl"
#include "space.glsl"

// 同一表面的单侧差分避免岸壁深度跳变把水底法线拉向屏外前景。
vec3 waterBedPoint(vec2 pixel, sampler2D opaqueDepth) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 uv = (clamp(pixel, vec2(0.0), size - 1.0) + 0.5) / size;
    float depth = texture2D(opaqueDepth, uv).r;
    return screenToView(uv, min(depth, 0.99999));
}

vec3 waterBedNormal(vec2 uv, vec3 centre, sampler2D opaqueDepth) {
    vec2 pixel = floor(uv * vec2(viewWidth, viewHeight));
    vec3 left = waterBedPoint(pixel - vec2(1.0, 0.0), opaqueDepth);
    vec3 right = waterBedPoint(pixel + vec2(1.0, 0.0), opaqueDepth);
    vec3 down = waterBedPoint(pixel - vec2(0.0, 1.0), opaqueDepth);
    vec3 up = waterBedPoint(pixel + vec2(0.0, 1.0), opaqueDepth);
    vec3 dx = abs(left.z - centre.z) < abs(right.z - centre.z) ? centre - left : right - centre;
    vec3 dy = abs(down.z - centre.z) < abs(up.z - centre.z) ? centre - down : up - centre;
    vec3 fallback = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    vec3 normal = safeNormalize(cross(dx, dy), fallback);
    normal *= dot(normal, -centre) >= 0.0 ? 1.0 : -1.0;
    return normalize(mat3(gbufferModelViewInverse) * normal);
}

// 先检查每个颜色纹素的几何，再插值；天空黑底、岸上前景与异面颜色不混入水底。
vec3 waterTransmissionColor(sampler2D scene, sampler2D opaqueDepth, vec2 uv,
                            vec3 bedWorld, vec3 bedNormal, float waterHeight) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    float tolerance = max(0.02, length(bedWorld - cameraPosition) * 0.002);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(base + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            vec2 sampleUv = (cell + 0.5) / size;
            float depth = texture2D(opaqueDepth, sampleUv).r;
            if (depth >= 0.999999) continue;
            vec3 world = viewToAbsoluteWorld(screenToView(sampleUv, depth));
            if (world.y >= waterHeight - 0.005 || abs(dot(world - bedWorld, bedNormal)) > tolerance) continue;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                * (y == 0 ? 1.0 - fraction.y : fraction.y);
            sum += texture2D(scene, sampleUv).rgb * weight;
            total += weight;
        }
    }
    vec2 centreUv = (clamp(floor(uv * size), vec2(0.0), size - 1.0) + 0.5) / size;
    return total > 0.00001 ? sum / total : texture2D(scene, centreUv).rgb;
}

vec2 waterRefractionUv(vec2 uv, vec3 position, vec3 normal, vec3 bedWorld,
                       vec3 bedNormal, sampler2D opaqueDepth) {
    if (WATER_REFRACTION_STRENGTH <= 0.0) {
        return uv;
    }
    vec3 origin = viewToAbsoluteWorld(position);
    vec3 incident = normalize(position);
    vec3 direction = normalize(mat3(gbufferModelViewInverse)
        * refract(incident, normal, 1.0 / WATER_IOR));
    float denominator = dot(bedNormal, direction);
    if (abs(denominator) < 0.04 || direction.y > -0.02) {
        return uv;
    }
    float distance = clamp(dot(bedNormal, bedWorld - origin) / denominator, 0.0, 48.0);
    vec2 candidate = uv;
    for (int index = 0; index < 3; index++) {
        vec3 target = origin + direction * distance;
        vec4 clip = gbufferProjection * vec4(worldToView(target - cameraPosition), 1.0);
        if (clip.w <= 0.001) {
            break;
        }
        vec2 projected = clip.xy / clip.w * 0.5 + 0.5;
        float edge = min(min(projected.x, projected.y), min(1.0 - projected.x, 1.0 - projected.y));
        projected = mix(uv, projected, smoothstep(0.005, 0.06, edge) * WATER_REFRACTION_STRENGTH);
        float depth = texture2D(opaqueDepth, projected).r;
        if (depth >= 0.999999) {
            break;
        }
        vec3 sampled = viewToAbsoluteWorld(screenToView(projected, depth));
        if (sampled.y > origin.y - 0.015 || length(sampled - cameraPosition) < length(position)) {
            break;
        }
        float correction = dot(bedNormal, sampled - target) / denominator;
        // 深度跨到岸壁时，屏幕点并不位于当前折射光线上；只接受已收敛的
        // 局部平面交点，避免将三次迭代中的中间坐标当成真实水底。
        float tolerance = max(0.025, distance * 0.004);
        float confidence = 1.0 - smoothstep(tolerance, tolerance * 4.0, abs(correction));
        if (confidence > 0.0) {
            candidate = mix(uv, projected, confidence);
        }
        distance = clamp(distance + correction, 0.0, 48.0);
    }
    // 置信度插值后的坐标仍须通过几何检查，防止中间点恰好跨到岸上物体。
    float finalDepth = texture2D(opaqueDepth, candidate).r;
    vec3 finalWorld = viewToAbsoluteWorld(screenToView(candidate, min(finalDepth, 0.99999)));
    if (finalDepth >= 0.999999 || finalWorld.y > origin.y - 0.015
        || length(finalWorld - cameraPosition) < length(position)) {
        return uv;
    }
    return candidate;
}
#endif
