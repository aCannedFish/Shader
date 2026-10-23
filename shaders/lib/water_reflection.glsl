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

uniform sampler2D colortex5;
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform sampler2D depthtex1;
uniform sampler2D colortex1;
uniform sampler2D colortex2;

// 粗糙度过滤：以命中像素为中心，再取四个按粗糙度和距离散开的采样。
// 只用 mip 0。mip 纹素在物体轮廓处已经把明亮天空平均进去，之后再怎么加权
// 也去不掉那圈亮边；旧版 mip 到 4–5 级，倒影因此像一块没有颜色的剪影。
// 深度权重是双边的：明显更近的前景和远得多的背景（含天空）都不进入倒影。
vec4 filteredWaterReflection(vec2 uv, float distanceToHit, float hitDepth, float roughness) {
    float radius = roughness * min(viewWidth, viewHeight) * 0.012
                 * clamp(distanceToHit / max(hitDepth, 1.0), 0.5, 2.0);
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 centre = texture2D(colortex6, uv).rgb;
    // 命中像素本身权重为 1，保证总权重不为零，不需要再向环境过渡。
    float weight = 1.0 / (1.0 + luma(centre));
    vec3 sum = centre * weight;
    float total = weight;
    for (int x = -1; x <= 1; x += 2) {
        for (int y = -1; y <= 1; y += 2) {
            vec2 sampleUv = clamp(uv + vec2(float(x), float(y)) * texel * radius,
                                  texel, 1.0 - texel);
            float depth = texture2D(depthtex1, sampleUv).r;
            float sampleDistance = depth >= 0.999999 ? far : -screenToView(sampleUv, depth).z;
            float depthWeight = smoothstep(hitDepth * 0.65, hitDepth * 0.90, sampleDistance)
                              * (1.0 - smoothstep(hitDepth * 1.6, hitDepth * 3.0, sampleDistance));
            vec3 radiance = texture2D(colortex6, sampleUv).rgb;
            // Karis 平均：少数明亮样本不会在植物倒影外圈形成白色高光边。
            weight = depthWeight / (1.0 + luma(radiance));
            sum += radiance * weight;
            total += weight;
        }
    }
    return vec4(sum / total, 1.0);
}

// 判断倒影中的点是否在水面以下：水下的方块不应出现在水面倒影里。
bool waterReflectionSubmerged(vec2 uv, vec3 origin) {
    vec2 pixelUv = reflectionPixelUv(uv);
    vec3 scene = screenToView(pixelUv, texture2D(depthtex1, pixelUv).r);
    return viewToAbsoluteWorld(scene).y < viewToAbsoluteWorld(origin).y - 0.12;
}

// 水面与固体、玻璃材质共用同一套屏幕空间求交。
vec4 traceWaterScene(vec3 origin, vec3 direction, float roughness, out float distanceToHit) {
    distanceToHit = 0.0;
    bool thinHit;
    // 水面本身不在不透明深度里，最近命中距离为 0：紧贴岸壁、树干的水面
    // 必须能命中几厘米外的墙面。旧版 0.25 格的下限让每条岸线都带一条天空色亮带。
    // 范围覆盖整个渲染距离，远山、远处树林不再渐变成天空。
    // 水面以下（0.12 格余量）的像素对水面以上的光线不存在。
    vec3 up = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    vec4 waterPlane = vec4(up, 0.12 - dot(up, origin));
    vec4 hit = traceScreenReflection(depthtex1, origin, direction, 0.0, far,
                                      WATER_REFLECTION_STEPS, waterPlane, thinHit);
    // 用命中像素上的可见表面判断是否在水下；薄命中时光线点本身位于物体内部。
    if (hit.a <= 0.0 || waterReflectionSubmerged(hit.xy, origin)) {
        return vec4(0.0);
    }
    distanceToHit = hit.z;
    float hitDepth = reflectionSceneDepth(depthtex1, hit.xy);
    vec4 radiance = filteredWaterReflection(hit.xy, distanceToHit, hitDepth, roughness);
    return vec4(radiance.rgb, hit.a * radiance.a);
}

// 屏幕光线未命中时，用阴影贴图判断相机看不到的遮挡（桥底、树冠下方、悬崖内侧）。
// skyLevel 为水面处的天光可见度，决定被挡背面的环境光。
vec4 waterReflectionOcclusion(vec3 origin, vec3 direction, float skyLevel,
                              out float hitDistance) {
    vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * direction);
    vec3 ambient = reflectionHiddenAmbient(rayWorld, vec2(0.0, 0.03125 + 0.9375 * skyLevel));
    return reflectionOcclusion(colortex6, depthtex1, origin, direction, ambient, hitDistance);
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

// 水底保持原屏幕坐标；按真实水内视线长度计算吸收与散射。
vec3 applyWaterReflection(vec3 color, vec2 uv, float normalVariance, vec4 backgroundLayer) {
    vec4 surface = readWaterSurface(colortex5, colortex1, uv);
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
    vec3 transmitted = applyTransparentLayer(texture2D(colortex6, uv).rgb, backgroundLayer);
    vec3 receiverNormal = waterReceiverNormal(opaqueWorld);
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
    float weight = waterFresnel(dot(normal, -incident), roughness) * WATER_REFLECTION_STRENGTH;
    if (weight > 0.001) {
        vec3 direction = normalize(reflect(incident, normal));
        float reflectionDistance;
        vec4 screenReflection = traceWaterScene(
            position + normal * 0.08, direction, roughness, reflectionDistance
        );
        // 光线被屏幕外或相机看不到的几何体挡住时，用遮挡物颜色代替天空；
        // 遮挡点明显更近时，屏幕命中是光线穿过遮挡物后打到的远处景物，舍弃。
        float occlusionDistance;
        vec4 occlusion = waterReflectionOcclusion(position, direction, surface.b,
                                                  occlusionDistance);
        if (reflectionOcclusionCloser(occlusion, occlusionDistance, reflectionDistance)) {
            screenReflection.a = 0.0;
        }
        vec3 environment = occlusion.rgb;
        // 完全可靠的命中无需计算体积云和天空回退。
        if (screenReflection.a < 1.0 && occlusion.a < 1.0) {
            vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * direction);
            // 波浪把少数反射方向压到地平线以下时，镜像回地平线上方查天空。
            // 旧版在这里退回水色，水面因此在夜晚和雨天仍是一片蓝色。
            rayWorld.y = abs(rayWorld.y);
            // surface.b 是水面处的天光可见度；树荫、屋檐下的水面天空倒影随之变暗。
            vec3 sky = waterEnvironment(originWorld, rayWorld,
                                        reflectionSkyLightWeight(surface.b), false);
            environment = mix(sky, occlusion.rgb, occlusion.a);
        }
        reflected = mix(environment, screenReflection.rgb, screenReflection.a)
                  * WATER_REFLECTION_BRIGHTNESS;
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
