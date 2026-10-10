/*
 * 水面光学：连续波浪折射、按光程衰减的透射、局部散射与 Fresnel 倒影。
 * 倒影在不透明深度上进行透视正确的 DDA，深度约束滤波模拟粗糙度。
 * 未命中/离屏时退回受当地天光限制的天空与方块云，屏幕边缘平滑过渡。
 */
#ifndef LIB_WATER_REFLECTION_GLSL
#define LIB_WATER_REFLECTION_GLSL

#include "water.glsl"
#include "space.glsl"
#include "color_space.glsl"
#include "clouds.glsl"
#include "water_lighting.glsl"
#include "water_volume.glsl"
#include "fog.glsl"

uniform sampler2D colortex5;
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform sampler2D depthtex1;

// 过滤半径随粗糙度和反射距离增加。深度权重避免邻近前景颜色漏进倒影。
vec3 filteredWaterReflection(vec2 uv, float distanceToHit, float hitDepth) {
    float radius = WATER_ROUGHNESS * 24.0 * clamp(distanceToHit / max(hitDepth, 1.0), 0.35, 3.0);
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 sampleUv = clamp(uv + vec2(float(x), float(y)) * texel * radius, texel, 1.0 - texel);
            float depth = texture2D(depthtex1, sampleUv).r;
            float sampleDistance = -screenToView(sampleUv, depth).z;
            float depthWeight = exp(-abs(sampleDistance - hitDepth) / max(hitDepth * 0.03, 0.2));
            float weight = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0) * depthWeight;
            sum += texture2D(colortex6, sampleUv).rgb * weight;
            total += weight;
        }
    }
    return sum / max(total, EPSILON);
}

// Q=position/w 与 k=1/w 沿投影线性插值，恢复深度时 Q/k，避免均匀世界步进漏采样。
vec4 traceWaterScene(vec3 origin, vec3 direction, bool reflection, out float distanceToHit) {
    distanceToHit = 0.0;
    float rayLength = min(far, 96.0);
    if (direction.z > 0.001) {
        rayLength = min(rayLength, (-near * 1.05 - origin.z) / direction.z);
    }
    if (rayLength <= 0.1) {
        return vec4(0.0);
    }
    vec3 end = origin + direction * rayLength;
    vec4 h0 = gbufferProjection * vec4(origin, 1.0);
    vec4 h1 = gbufferProjection * vec4(end, 1.0);
    float k0 = 1.0 / h0.w;
    float k1 = 1.0 / h1.w;
    vec3 q0 = origin * k0;
    vec3 q1 = end * k1;
    vec2 uv0 = h0.xy * k0 * 0.5 + 0.5;
    vec2 uv1 = h1.xy * k1 * 0.5 + 0.5;
    vec2 pixels = (uv1 - uv0) * vec2(viewWidth, viewHeight);
    float extent = max(abs(pixels.x), abs(pixels.y));
    if (extent < 1.0) {
        return vec4(0.0);
    }
    float stride = clamp(extent / 96.0, 2.0, 12.0);
    float stepT = stride / extent;
    float previousT = 0.0;
    float previousDepth = -origin.z;
    for (int stepIndex = 0; stepIndex < 96; stepIndex++) {
        float t = min((float(stepIndex) + 1.0) * stepT, 1.0);
        vec2 uv = mix(uv0, uv1, t);
        if (any(lessThan(uv, vec2(0.002))) || any(greaterThan(uv, vec2(0.998)))) {
            break;
        }
        vec3 position = mix(q0, q1, t) / mix(k0, k1, t);
        float rayDepth = -position.z;
        float depth = texture2D(depthtex1, uv).r;
        float sceneDepth = -screenToView(uv, depth).z;
        float thickness = 0.20 + sceneDepth * 0.006;
        float low = min(previousDepth, rayDepth);
        float high = max(previousDepth, rayDepth);
        bool overlap = high >= sceneDepth && low <= sceneDepth + thickness;
        if (depth < 0.999999 && overlap && length(position - origin) > 0.30) {
            // 缩小命中区间以消除大步长造成的倒影错位。
            float left = previousT;
            float right = t;
            for (int refinement = 0; refinement < 5; refinement++) {
                float mid = (left + right) * 0.5;
                vec2 testUv = mix(uv0, uv1, mid);
                float testDepth = texture2D(depthtex1, testUv).r;
                float surface = -screenToView(testUv, testDepth).z;
                float ray = -mix(q0.z, q1.z, mid) / mix(k0, k1, mid);
                if (ray > surface) {
                    right = mid;
                } else {
                    left = mid;
                }
            }
            float hitT = (left + right) * 0.5;
            vec2 hitUv = mix(uv0, uv1, hitT);
            vec3 hit = mix(q0, q1, hitT) / mix(k0, k1, hitT);
            float hitDepth = -screenToView(hitUv, texture2D(depthtex1, hitUv).r).z;
            vec2 edge = min(hitUv, 1.0 - hitUv);
            float confidence = smoothstep(0.0, 0.045, min(edge.x, edge.y));
            confidence *= 1.0 - smoothstep(rayLength * 0.80, rayLength, length(hit - origin));
            vec3 geometry = screenToView(hitUv, texture2D(depthtex1, hitUv).r);
            vec3 geometryWorld = viewToAbsoluteWorld(geometry);
            vec3 originWorld = viewToAbsoluteWorld(origin);
            // 折射只能命中水面下方的几何，避免岸边前景错误拖进水底。
            bool invalidRefraction = !reflection && geometryWorld.y > originWorld.y + 0.08;
            bool invalidReflection = reflection && (isEyeInWater == 1
                ? geometryWorld.y > originWorld.y + 0.02
                : geometryWorld.y < originWorld.y - 0.12);
            if (invalidRefraction || invalidReflection) {
                previousT = t;
                previousDepth = rayDepth;
                continue;
            }
            distanceToHit = length(geometry - origin);
            // Underwater viewing keeps sharp samples, including internal reflection.
            vec3 radiance = reflection && isEyeInWater == 0
                ? filteredWaterReflection(hitUv, distanceToHit, hitDepth)
                : texture2D(colortex6, hitUv).rgb;
            return vec4(radiance, confidence);
        }
        previousT = t;
        previousDepth = rayDepth;
        if (t >= 1.0) {
            break;
        }
    }
    return vec4(0.0);
}

// 天空回退保留同一套天空/云输入；封闭水域的天空辐射为零。
vec3 waterEnvironment(vec3 originWorld, vec3 rayWorld, float skyVisibility, bool celestial) {
    if (skyVisibility <= 0.001) {
        return vec3(0.0);
    }
    vec3 sky = skyAtmosphereRadiance(rayWorld) + skyStars(rayWorld);
    if (celestial) {
        sky += skyCelestialRadiance(rayWorld);
    }
    vec4 cloud = traceVolumetricCloudsFrom(originWorld, rayWorld, CLOUD_DISTANCE, true);
    return (cloud.rgb + sky * (1.0 - cloud.a)) * skyVisibility;
}

// 从水面的线性深度恢复位置，完整保留折射所需的三维边界。
vec3 waterSurfacePosition(vec2 uv, float linearDepth) {
    vec3 ray = screenToView(uv, 0.5);
    return ray * (linearDepth / max(-ray.z, EPSILON));
}

// 投影方向差形成连续的波浪折射；平整水面保留现有池底的对齐。
// 单层屏幕深度无法重建新露出的池壁，避免大角度追踪与原图切换产生双层轮廓。
vec2 waterRefractionUv(vec2 uv, vec3 position, vec3 normal, vec3 incident,
                       float pathLength, vec3 originWorld) {
    float eta = mix(1.0, 1.0 / 1.333, WATER_REFRACTION_STRENGTH);
    vec3 flatNormal = normalize(mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0));
    vec3 flatDirection = refract(incident, flatNormal, eta);
    vec3 waveDirection = refract(incident, normal, eta);
    vec4 flatClip = gbufferProjection * vec4(position + flatDirection * pathLength, 1.0);
    vec4 waveClip = gbufferProjection * vec4(position + waveDirection * pathLength, 1.0);
    vec2 offset = (waveClip.xy / waveClip.w - flatClip.xy / flatClip.w) * 0.5;
    vec2 candidate = uv;
    float scale = 1.0;
    for (int attempt = 0; attempt < 5; attempt++) {
        vec2 sampleUv = uv + offset * scale;
        bool inside = all(greaterThan(sampleUv, vec2(0.002)))
                   && all(lessThan(sampleUv, vec2(0.998)));
        if (inside) {
            float depth = texture2D(depthtex1, sampleUv).r;
            vec3 geometry = screenToView(sampleUv, depth);
            vec3 world = viewToAbsoluteWorld(geometry);
            if (depth < 0.999999 && world.y <= originWorld.y + 0.02) {
                candidate = sampleUv;
                break;
            }
        }
        scale *= 0.5;
    }
    return candidate;
}

// Snell 折射寻找水底；深度吸收、少量局部散射与 Fresnel 反射共同决定水色。
vec3 applyWaterReflection(vec3 color, vec2 uv, vec3 unusedViewPosition) {
    vec4 surface = texture2D(colortex5, uv);
    if (surface.a <= 0.001 || isEyeInWater != 0) {
        return color;
    }
    vec3 position = waterSurfacePosition(uv, surface.a);
    vec3 normal = decodeWaterNormal(surface.xy);
    vec3 incident = normalize(position);
    vec3 originWorld = viewToAbsoluteWorld(position);
    vec4 scattering = texture2D(colortex7, uv);

    float opaqueDepth = texture2D(depthtex1, uv).r;
    vec3 opaquePosition = screenToView(uv, opaqueDepth);
    vec3 opaqueWorld = viewToAbsoluteWorld(opaquePosition);
    float verticalDepth = max(originWorld.y - opaqueWorld.y, 0.0);
    float eta = mix(1.0, 1.0 / 1.333, WATER_REFRACTION_STRENGTH);
    vec3 refractionWorld = mat3(gbufferModelViewInverse) * refract(incident, normal, eta);
    float waterDistance = opaqueDepth < 0.999999
        ? verticalDepth / max(-refractionWorld.y, 0.15) : 24.0;
    waterDistance = clamp(waterDistance, 0.0, 48.0);
    vec2 refractionUv = uv;
    if (WATER_REFRACTION_STRENGTH > 0.0) {
        refractionUv = waterRefractionUv(uv, position, normal, incident, waterDistance, originWorld);
    }
    // 每个像素只读取一个水底位置，折射强度控制方向，不叠加第二幅池底。
    vec3 transmitted = texture2D(colortex6, refractionUv).rgb;

    // Beer-Lambert 衰减只削弱透射，不用恒定蓝色遮盖水底。
    vec3 extinction = waterExtinctionCoefficient();
    vec3 transmittance = exp(-extinction * waterDistance);
    transmitted *= transmittance;
    transmitted += scattering.rgb * (1.0 - transmittance) * 0.30;
    transmitted = mix(transmitted, scattering.rgb, scattering.a);

    vec3 reflected = vec3(0.0);
    float fresnel = waterFresnel(max(dot(normal, -incident), 0.0));
    float weight = fresnel * WATER_REFLECTION_STRENGTH;
    if (weight > 0.001) {
        vec3 direction = normalize(reflect(incident, normal));
        vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * direction);
        vec3 environment = waterEnvironment(originWorld, rayWorld, surface.b, false);
        float reflectionDistance;
        vec4 screenReflection = traceWaterScene(position + normal * 0.08, direction, true, reflectionDistance);
        reflected = mix(environment, screenReflection.rgb, screenReflection.a) * WATER_REFLECTION_BRIGHTNESS;
    }
    vec3 result = mix(transmitted, reflected, weight);

    vec4 shadowClip = shadowProjection * shadowModelView * gbufferModelViewInverse * vec4(position, 1.0);
    shadowClip.xyz = distortShadow(shadowClip.xyz);
    float directVisibility = waterOpaqueShadow(shadowClip, normal, length(position))
                           * smoothstep(0.80, 0.99, surface.b);
    directVisibility *= cloudProjectedShadow(originWorld, normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
    result += waterDirectSpecular(normal, position) * directVisibility
            * WATER_REFLECTION_STRENGTH * WATER_SPECULAR_STRENGTH;
    result = applyFog(result, length(position));
    return result;
}

#endif
