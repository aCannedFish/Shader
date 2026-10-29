/*
 * 水面光学：固定水底采样、按光程衰减的透射、局部散射与 Fresnel 倒影。
 * 倒影在不透明深度上进行透视正确的 DDA，深度约束滤波模拟粗糙度。
 * 未命中/离屏时先用阴影贴图找相机看不到的遮挡物，再退回受当地天光限制的
 * 天空与方块云。
 */
#ifndef LIB_WATER_REFLECTION_GLSL
#define LIB_WATER_REFLECTION_GLSL

#include "water.glsl"
#include "screen_reflection.glsl"
#include "screen_reflection_adaptive.glsl"
#include "reflection_source.glsl"
#include "reflection_medium.glsl"
#include "color_space.glsl"
#include "clouds.glsl"
#include "water_lighting.glsl"
#include "water_volume.glsl"
#include "water_effects.glsl"
#include "fog.glsl"
#include "materials.glsl"
#include "material_environment.glsl"
#include "transparency.glsl"
#include "reflection_occlusion.glsl"
#include "water_refraction.glsl"
#include "rain_ripples.glsl"

uniform sampler2D colortex5;
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
#ifdef WORLD_BASE_OPTICS
uniform sampler2D colortex3;
#endif
#ifdef WORLD_REFLECTION_CACHE
#include "/lib/world/reflection_history.glsl"
#endif

// Colour reconstruction validates each mip-zero texel against the hit plane.
vec4 filteredWaterReflection(vec2 uv, float distanceToHit, float hitDepth, float roughness) {
    return reflectionSourceFiltered(colortex6, depthtex1, uv, hitDepth, distanceToHit, roughness);
}

// 判断倒影中的点是否在水面以下：水下的方块不应出现在水面倒影里。
bool waterReflectionSubmerged(vec2 uv, vec3 origin) {
    vec2 pixelUv = reflectionPixelUv(uv);
    vec3 scene = screenToView(pixelUv, texture2D(depthtex1, pixelUv).r);
    return viewToAbsoluteWorld(scene).y < viewToAbsoluteWorld(origin).y - 0.12;
}

// 水面与固体、玻璃材质共用同一套屏幕空间求交。
vec4 traceWaterScene(vec3 origin, vec3 direction, float roughness,
    out float distanceToHit, out float confidence) {
    distanceToHit = 0.0;
    confidence = 1.0;
    // 水面本身不在不透明深度里，最近命中距离为 0：紧贴岸壁、树干的水面
    // 必须能命中几厘米外的墙面。旧版 0.25 格的下限让每条岸线都带一条天空色亮带。
    // 范围覆盖整个渲染距离，远山、远处树林不再渐变成天空。
    // 水面以下（0.12 格余量）的像素对水面以上的光线不存在。
    vec3 up = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    vec4 waterPlane = vec4(up, 0.12 - dot(up, origin));
    int budget = WATER_REFLECTION_STEPS;
#ifdef WORLD_GPU_BACKEND
    // Contact reflections have little travel distance but need enough shrinking
    // steps to resolve an actual bank rather than a broad depth approximation.
    vec4 originClip = gbufferProjection * vec4(origin, 1.0);
    vec2 originUv = originClip.xy / originClip.w * 0.5 + 0.5;
    vec2 bedUv = reflectionPixelUv(originUv);
    float bedDepth = texture2D(depthtex1, bedUv).r;
    if (bedDepth < 0.999999) {
        float separation = length(screenToView(bedUv, bedDepth) - origin);
        if (separation < 1.0) budget = max(budget, 32);
    }
#endif
    ScreenReflectionHit traced = traceAdaptiveReflectionDetailed(colortex6, depthtex1,
        origin, direction, 0.001, far, budget, waterPlane);
    vec4 hit = vec4(traced.uv, traced.distance, traced.coverage);
    confidence = traced.confidence;
    // 用命中像素上的可见表面判断是否在水下；薄命中时光线点本身位于物体内部。
    if (hit.a <= 0.0 || waterReflectionSubmerged(hit.xy, origin)) {
        return vec4(0.0);
    }
    distanceToHit = hit.z;
    float hitDepth = reflectionSceneDepth(depthtex1, hit.xy);
    vec4 radiance = filteredWaterReflection(hit.xy, distanceToHit, hitDepth, roughness);
    return vec4(reflectionAirMedium(radiance.rgb, hit.z, direction), hit.a * radiance.a);
}

vec4 traceWaterScene(vec3 origin, vec3 direction, float roughness, out float distanceToHit) {
    float confidence;
    return traceWaterScene(origin, direction, roughness, distanceToHit, confidence);
}

// 自适应步进在镂空轮廓附近可能耗尽预算。已知有遮挡时，再用透视深度DDA
// 找实际屏幕表面，优先恢复纹理；不会对整片天空重复追踪。
vec4 recoverWaterScene(vec3 origin, vec3 direction, float roughness, out float distanceToHit) {
    distanceToHit = 0.0;
    vec3 up = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    vec4 waterPlane = vec4(up, 0.12 - dot(up, origin));
    bool thinHit;
    vec4 hit = traceScreenReflection(depthtex1, origin, direction, 0.001, far,
        min(max(WATER_REFLECTION_STEPS, 24), 64), waterPlane, thinHit);
    if (hit.a <= 0.0 || waterReflectionSubmerged(hit.xy, origin)) {
        return vec4(0.0);
    }
    distanceToHit = hit.z;
    vec4 radiance = filteredWaterReflection(hit.xy, hit.z,
        reflectionSceneDepth(depthtex1, hit.xy), roughness);
    return vec4(reflectionAirMedium(radiance.rgb, hit.z, direction), radiance.a);
}

// 屏幕光线未命中时，用阴影贴图判断相机看不到的遮挡（桥底、树冠下方、悬崖内侧）。
// skyLevel 为水面处的天光可见度，决定被挡背面的环境光。
vec4 waterReflectionOcclusion(vec3 origin, vec3 direction, float skyLevel,
                              float screenDistance, out float hitDistance) {
    vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * direction);
    vec3 ambient = reflectionHiddenAmbient(rayWorld, vec2(0.0, 0.03125 + 0.9375 * skyLevel));
#ifdef WORLD_GPU_BACKEND
    vec3 up = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    vec4 waterPlane = vec4(up, 0.12 - dot(up, origin));
    float maximum = screenDistance > 0.0
        ? screenDistance + max(0.05, screenDistance * 0.015) : far;
    return reflectionOcclusionPlane(colortex6, depthtex1, origin, direction, ambient,
        waterPlane, maximum, hitDistance);
#else
    return reflectionOcclusion(colortex6, depthtex1, origin, direction, ambient, hitDistance);
#endif
}

// 水的 Fresnel。物理上的 Schlick 曲线（F0 = 0.02，五次方）在常见的俯视角下
// 几乎不反射，水面因此被水色主导。这里参考 Sildur 的做法：略高的 F0 与四次方
// 曲线，使中等角度也能看到明显的天空和景物倒影；粗糙水面在掠射时略降低峰值。
float waterFresnel(float cosine, float roughness) {
    float f0 = 0.05;
    float grazing = max(1.0 - roughness * 0.6, f0);
    return f0 + (grazing - f0) * pow4(1.0 - clamp(cosine, 0.0, 1.0));
}

// 天空回退保留同一套天空/云输入；封闭水域的天空辐射为零。
vec3 waterEnvironment(vec3 originWorld, vec3 rayWorld, float skyVisibility, bool celestial) {
#if SIMPLE_DIMENSION == 1
    return mix(dimensionAmbient(rayWorld) * AMBIENT_STRENGTH,
               skyAtmosphereRadiance(rayWorld) * 1.8, END_ATMOSPHERE * 0.65);
#elif SIMPLE_DIMENSION == -1
    return dimensionAmbient(rayWorld) * AMBIENT_STRENGTH;
#endif
    if (skyVisibility <= 0.001) {
        return vec3(0.0);
    }
    vec3 sky = skyAtmosphereRadiance(rayWorld) + skyStars(rayWorld);
    if (celestial) {
        sky += skyCelestialRadiance(rayWorld);
    }
#if WATER_REFLECTION_CLOUDS == 1
    vec4 cloud = traceVolumetricCloudsFrom(originWorld, rayWorld, CLOUD_DISTANCE, true);
#else
    vec4 cloud = cloudEnvironment(rayWorld);
#endif
    return (cloud.rgb + sky * (1.0 - cloud.a)) * skyVisibility;
}

// Query unweighted reflected radiance before the water BRDF and air medium.
// Confidence guides temporal reuse; it never acts as a sky blend opacity.
vec4 queryWaterRadiance(vec3 position, vec3 direction, float roughness, float skyLevel) {
    vec3 originWorld = viewToAbsoluteWorld(position);
    float screenDistance;
    float screenConfidence;
    vec4 screen = traceWaterScene(position + mat3(gbufferModelView) * vec3(0.0, 0.001, 0.0),
        direction, roughness, screenDistance, screenConfidence);
    float worldDistance;
    vec4 world = waterReflectionOcclusion(position, direction, skyLevel, screenDistance, worldDistance);
    if (screen.a <= 0.0 && world.a > 0.0) {
        vec3 origin = position + mat3(gbufferModelView) * vec3(0.0, 0.001, 0.0);
        vec4 recovered = recoverWaterScene(origin, direction, roughness, screenDistance);
        if (recovered.a > 0.0) {
            screen = recovered;
        }
    }
    // 屏幕命中已经包含真实纹理和光照；同一距离的回退不能用平均环境色覆盖它。
    if (reflectionOcclusionCloser(world, worldDistance, screenDistance)) {
        return vec4(world.rgb, 0.9);
    }
    if (screen.a >= 0.999) return vec4(screen.rgb, 1.0);
    // 缺少屏幕命中时仍保留隐藏面的保守回退；低置信度不能压掉已有真实纹理。
    if (world.a > 0.0 && screen.a <= 0.0) return vec4(world.rgb, 0.6);
    vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * direction);
    vec3 environment = waterEnvironment(originWorld, rayWorld,
        reflectionSkyLightWeight(skyLevel), false);
    return vec4(mix(environment, screen.rgb, screen.a), 0.25);
}

// 折射改变水底的投影位置；吸收仍由采样处的真实水内距离决定。
vec3 applyWaterReflection(vec3 color, vec2 uv, float normalVariance) {
    vec4 surface = readWaterSurface(colortex5, colortex1, uv);
    if (surface.a <= 0.001 || isEyeInWater != 0) {
        return color;
    }
    vec3 position = waterSurfacePosition(uv, surface.a);
    vec3 normal = decodeWaterNormal(surface.xy);
    vec3 incident = normalize(position);
    vec3 originWorld = viewToAbsoluteWorld(position);
    vec4 scattering = vec4(readWaterScattering(colortex5, colortex7, uv), 1.0);

    float opaqueDepth = texture2D(depthtex1, uv).r;
    vec3 opaquePosition = screenToView(uv, min(opaqueDepth, 0.99999));
    vec3 opaqueWorld = viewToAbsoluteWorld(opaquePosition);
    vec3 receiverNormal = waterBedNormal(uv, opaquePosition, depthtex1);
    // 透射采用实际位移高度场的斜率；放大的微表面高光法线不代表一整段水柱的几何。
    // 水底变浅与波浪偏折均来自下方同一次 Snell 求解，不额外变换水底深度。
    vec3 opticalNormal = vec3(0.0, 1.0, 0.0);
#if ENABLE_WATER_WAVES == 1
    opticalNormal = getWaterWaveNormal(originWorld.xz, frameTimeCounter);
#endif
    float footprint = 2.0 * abs(gbufferProjectionInverse[1][1]) * length(position)
        / (max(viewHeight, 1.0) * max(abs(dot(normalize(position),
            mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0))), 0.1));
    vec2 rainSlope = rainRippleSlope(originWorld.xz, frameTimeCounter, footprint)
        * smoothstep(0.95, 0.995, surface.b);
    opticalNormal = mat3(gbufferModelView)
        * normalize(opticalNormal + vec3(-rainSlope.x, 0.0, -rainSlope.y));
    vec2 transmittedUv = opaqueDepth < 0.999999
        ? waterRefractionUv(uv, position, opticalNormal, opaqueWorld, receiverNormal,
            depthtex1, colortex5, colortex1) : uv;
    vec2 sourceUv = waterBedUv(transmittedUv);
    opaqueDepth = texture2D(depthtex1, sourceUv).r;
    opaquePosition = screenToView(sourceUv, min(opaqueDepth, 0.99999));
    opaqueWorld = viewToAbsoluteWorld(opaquePosition);
    receiverNormal = waterBedNormal(sourceUv, opaquePosition, depthtex1);
    // 水后的玻璃等与水底使用同一折射坐标；岸上的前景层继续由主像素合成。
    vec4 backgroundLayer = texture2D(colortex2, sourceUv);
    vec4 sourceWater = readWaterSurface(colortex5, colortex1, sourceUv);
    float sourceDepth = -screenToView(sourceUv, texture2D(depthtex0, sourceUv).r).z;
    if (transparentLayerInFront(sourceDepth, sourceWater.a, backgroundLayer.a)) {
        backgroundLayer = vec4(0.0);
    }
    float verticalDepth = max(originWorld.y - opaqueWorld.y, 0.0);
    float waterDistance = opaqueDepth < 0.999999 ? length(opaquePosition - position) : 24.0;
    waterDistance = clamp(waterDistance, 0.0, 48.0);
#ifdef WORLD_BASE_OPTICS
    vec3 transmitted = applyTransparentLayer(waterTransmissionColor(colortex3, depthtex1,
        transmittedUv, opaqueWorld, receiverNormal, originWorld.y), backgroundLayer);
#else
    vec3 transmitted = applyTransparentLayer(waterTransmissionColor(colortex6, depthtex1,
        transmittedUv, opaqueWorld, receiverNormal, originWorld.y), backgroundLayer);
#endif
    if (opaqueDepth < 0.999999) {
        transmitted *= waterCausticGain(opaqueWorld, receiverNormal, originWorld.y, surface.b);
    }

    // 水上观察时增加随光程累积的散射遮蔽，浅水保留水底，深水以水色为主。
    // 此密度只用于水面合成，避免同时缩短水下相机的可见距离。
    vec3 extinction = waterExtinctionCoefficient() + vec3(WATER_SURFACE_OPACITY * 3.0);
    vec3 transmittance = exp(-extinction * waterDistance);
    transmitted *= transmittance;
    // 遮蔽水底的部分由受光水色补足，不再额外折半，避免不透明深水趋近蓝黑。
    transmitted += scattering.rgb * (1.0 - transmittance);
    // 浅水薄层逐渐变透明，使近岸与水底细节自然显现。
    float surfaceOpacity = texture2D(colortex1, uv).g * smoothstep(0.0, 1.5, verticalDepth);
    transmitted = mix(transmitted, scattering.rgb, surfaceOpacity);

    vec3 reflected = vec3(0.0);
    float roughness = sqrt(sqrt(pow4(WATER_ROUGHNESS) + min(2.0 * normalVariance, 0.035)));
    float coherence = 1.0 / (1.0 + roughness);
    vec3 geometricNormal = normalize(mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0));
    // 水下窗口需要清晰的波浪起伏；水上倒影使用更平缓的光学斜率，
    // 避免同一组放大法线把相邻倒影拉成相互交叠的碎片。
    vec3 reflectionNormal = normalize(mix(geometricNormal, normal, 0.45));
    vec3 direction = normalize(reflect(incident, reflectionNormal));
    float visibility = reflectionGeometricVisibility(dot(geometricNormal, -incident),
        dot(geometricNormal, direction), roughness);
    float weight = waterFresnel(dot(reflectionNormal, -incident), roughness)
        * WATER_REFLECTION_STRENGTH * visibility;
    if (dot(reflectionNormal, -incident) <= 0.0) weight = 0.0;
    if (weight > 0.001) {
        vec4 radiance = vec4(0.0);
#if defined(WORLD_REFLECTION_CACHE) && !defined(WORLD_REFLECTION_CACHE_WRITE)
        if (waterDistance >= 1.0) {
            radiance = worldWaterReflectionAt(uv, position, reflectionNormal);
        }
#endif
        if (radiance.a <= 0.0) {
            radiance = queryWaterRadiance(position, direction, roughness, surface.b);
        }
        reflected = radiance.rgb * WATER_REFLECTION_BRIGHTNESS;
    }
    // 倒影直接与透射混合：夜晚、雨天的天空暗而灰，水面也随之变暗、变灰。
    vec3 result = mix(transmitted, reflected, weight);

    vec4 shadowClip = shadowProjection * shadowModelView * gbufferModelViewInverse * vec4(position, 1.0);
    float directSky = smoothstep(0.80, 0.99, surface.b);
    if (directSky > 0.001 && WATER_REFLECTION_STRENGTH * WATER_SPECULAR_STRENGTH > 0.0) {
        float directVisibility = waterOpaqueShadow(shadowClip, normal, length(position)) * directSky;
        directVisibility *= cloudProjectedShadow(originWorld,
            normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
        // 随机噪声法线的高频成分比正弦多，高光下限略放宽，避免远处一片细碎白点。
        float glintRoughness = sqrt(sqrt(pow4(max(WATER_ROUGHNESS * 0.6, 0.15))
                                       + min(2.0 * normalVariance, 0.035)));
        result += waterDirectSpecular(normal, position, glintRoughness) * directVisibility
                * WATER_REFLECTION_STRENGTH * WATER_SPECULAR_STRENGTH * coherence;
    }
    result = applyFog(result, length(position));
    return result;
}

#endif
