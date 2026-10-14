/*
 * 水面光学：固定水底采样、按光程衰减的透射、局部散射与 Fresnel 倒影。
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
#include "water_effects.glsl"
#include "fog.glsl"

uniform sampler2D colortex5;
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform sampler2D depthtex1;

// 过滤半径随粗糙度和反射距离增加。深度权重避免邻近前景颜色漏进倒影。
vec3 filteredWaterReflection(vec2 uv, float distanceToHit, float hitDepth) {
    float radius = WATER_ROUGHNESS * min(viewWidth, viewHeight) * 0.032
                 * clamp(distanceToHit / max(hitDepth, 1.0), 0.5, 2.0);
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 sampleUv = clamp(uv + vec2(float(x), float(y)) * texel * radius, texel, 1.0 - texel);
            float depth = texture2D(depthtex1, sampleUv).r;
            float sampleDistance = -screenToView(sampleUv, depth).z;
            // 背景可以进入粗糙反射的滤波核；只拒绝明显更近的前景。
            // 对称深度拒绝会把物体轮廓锁成锐利的镜面。
            float depthWeight = smoothstep(hitDepth * 0.65, hitDepth * 0.90, sampleDistance);
            float weight = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0) * depthWeight;
            sum += texture2D(colortex6, sampleUv).rgb * weight;
            total += weight;
        }
    }
    return sum / max(total, EPSILON);
}

// Q=position/w 与 k=1/w 沿投影线性插值，恢复深度时 Q/k，避免均匀世界步进漏采样。
vec4 traceWaterScene(vec3 origin, vec3 direction, out float distanceToHit) {
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
    float stride = clamp(extent / 64.0, 2.0, 18.0);
    float stepT = stride / extent;
    float previousT = 0.0;
    float previousDepth = -origin.z;
    for (int stepIndex = 0; stepIndex < 64; stepIndex++) {
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
            float sampledDepth = texture2D(depthtex1, hitUv).r;
            vec3 geometry = screenToView(hitUv, sampledDepth);
            float hitDepth = -geometry.z;
            vec2 edge = min(hitUv, 1.0 - hitUv);
            float confidence = smoothstep(0.0, 0.045, min(edge.x, edge.y));
            confidence *= 1.0 - smoothstep(rayLength * 0.80, rayLength, length(hit - origin));
            vec3 geometryWorld = viewToAbsoluteWorld(geometry);
            vec3 originWorld = viewToAbsoluteWorld(origin);
            // 水上倒影排除水面以下的几何，避免水底再次叠入反射。
            if (geometryWorld.y < originWorld.y - 0.12) {
                previousT = t;
                previousDepth = rayDepth;
                continue;
            }
            distanceToHit = length(geometry - origin);
            vec3 radiance = filteredWaterReflection(hitUv, distanceToHit, hitDepth);
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

// 水底保持原屏幕坐标；按真实水内视线长度计算吸收与散射。
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
    float waterDistance = opaqueDepth < 0.999999 ? length(opaquePosition - position) : 24.0;
    waterDistance = clamp(waterDistance, 0.0, 48.0);
    vec3 transmitted = texture2D(colortex6, uv).rgb;
    vec3 receiverNormal = waterReceiverNormal(opaqueWorld);
    if (opaqueDepth < 0.999999) {
        transmitted *= waterCausticGain(opaqueWorld, receiverNormal, originWorld.y, surface.b);
    }

    // Beer-Lambert 衰减只削弱透射，不用恒定蓝色遮盖水底。
    vec3 extinction = waterExtinctionCoefficient();
    vec3 transmittance = exp(-extinction * waterDistance);
    transmitted *= transmittance;
    transmitted += scattering.rgb * (1.0 - transmittance) * 0.30;
    // 浅水薄层逐渐变透明，使近岸与水底细节自然显现。
    float surfaceOpacity = scattering.a * smoothstep(0.0, 1.5, verticalDepth);
    transmitted = mix(transmitted, scattering.rgb, surfaceOpacity);

    vec3 reflected = vec3(0.0);
    float fresnel = waterFresnel(max(dot(normal, -incident), 0.0));
    float coherence = 1.0 / (1.0 + 2.0 * WATER_ROUGHNESS);
    float weight = fresnel * WATER_REFLECTION_STRENGTH;
    if (weight > 0.001) {
        vec3 direction = normalize(reflect(incident, normal));
        float reflectionDistance;
        vec4 screenReflection = traceWaterScene(
            position + normal * 0.08, direction, reflectionDistance
        );
        // 完全可靠的屏幕命中无需计算体积云和天空回退。
        vec3 environment = vec3(0.0);
        if (screenReflection.a < 1.0) {
            vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * direction);
            environment = waterEnvironment(originWorld, rayWorld, surface.b, false);
        }
        reflected = mix(environment, screenReflection.rgb, screenReflection.a)
                  * WATER_REFLECTION_BRIGHTNESS;
    }
    // 较粗糙的水面把一部分清晰倒影过渡到当地散射，避免波浪镜面观感。
    reflected = mix(scattering.rgb, reflected, coherence);
    vec3 result = mix(transmitted, reflected, weight);

    vec4 shadowClip = shadowProjection * shadowModelView * gbufferModelViewInverse * vec4(position, 1.0);
    float directSky = smoothstep(0.80, 0.99, surface.b);
    if (directSky > 0.001 && WATER_REFLECTION_STRENGTH * WATER_SPECULAR_STRENGTH > 0.0) {
        float directVisibility = waterOpaqueShadow(shadowClip, normal, length(position)) * directSky;
        directVisibility *= cloudProjectedShadow(originWorld,
            normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
        result += waterDirectSpecular(normal, position) * directVisibility
                * WATER_REFLECTION_STRENGTH * WATER_SPECULAR_STRENGTH * coherence;
    }
    result = applyFog(result, length(position));
    return result;
}

#endif
