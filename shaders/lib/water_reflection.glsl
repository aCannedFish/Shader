/*
 * 水面光学：固定水底采样、按光程衰减的透射、局部散射与 Fresnel 倒影。
 * 倒影在不透明深度上进行透视正确的 DDA，深度约束滤波模拟粗糙度。
 * 未命中/离屏时退回受当地天光限制的天空与方块云，屏幕边缘平滑过渡。
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

uniform sampler2D colortex5;
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform sampler2D depthtex1;
uniform sampler2D colortex1;
uniform sampler2D colortex2;

// 过滤半径随粗糙度和反射距离增加。深度权重避免邻近前景颜色漏进倒影。
vec4 filteredWaterReflection(vec2 uv, float distanceToHit, float hitDepth, float roughness) {
    float radius = roughness * min(viewWidth, viewHeight) * 0.035
                 * clamp(distanceToHit / max(hitDepth, 1.0), 0.5, 2.0);
    float lod = max(log2(max(radius * 2.0, 1.0)), 0.0);
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int x = -1; x <= 1; x += 2) {
        for (int y = -1; y <= 1; y += 2) {
            vec2 sampleUv = clamp(uv + vec2(float(x), float(y)) * texel * radius * 0.35,
                                  texel, 1.0 - texel);
            float depth = texture2D(depthtex1, sampleUv).r;
            // 天空一定在命中物后面，不需要为它重建视图位置。
            float sampleDistance = depth >= 0.999999 ? hitDepth : -screenToView(sampleUv, depth).z;
            // 背景可以进入粗糙反射的滤波核；只拒绝明显更近的前景。
            // 对称深度拒绝会把物体轮廓锁成锐利的镜面。
            float depthWeight = smoothstep(hitDepth * 0.65, hitDepth * 0.90, sampleDistance);
            // 每次读取连续的像素足迹，避免稀疏九点核产生多份锐利轮廓。
            sum += textureLod(colortex6, sampleUv, lod).rgb * depthWeight;
            total += depthWeight;
        }
    }
    return vec4(sum / max(total, EPSILON), clamp(total * 0.5, 0.0, 1.0));
}

// Water uses the same validated opaque intersection as solid and glass materials.
vec4 traceWaterScene(vec3 origin, vec3 direction, float roughness, out float distanceToHit) {
    distanceToHit = 0.0;
    vec4 hit = traceScreenReflection(depthtex1, origin, direction, min(far, 96.0),
                                      WATER_REFLECTION_STEPS);
    if (hit.a <= 0.0) {
        return vec4(0.0);
    }
    vec3 geometry = origin + direction * hit.z;
    // Exclude submerged geometry from the reflected layer.
    if (viewToAbsoluteWorld(geometry).y < viewToAbsoluteWorld(origin).y - 0.12) {
        return vec4(0.0);
    }
    distanceToHit = hit.z;
    vec4 radiance = filteredWaterReflection(hit.xy, distanceToHit, -geometry.z, roughness);
    // 窄缝或轮廓附近若没有足够有效样本，平滑过渡到环境，避免出现黑斑。
    return vec4(radiance.rgb, hit.a * radiance.a);
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
    // 保留少量正面环境倒影，掠射时逐渐增强；粗糙过滤继续柔化场景轮廓。
    SurfaceMaterial waterMaterial;
    waterMaterial.f0 = vec3(0.14);
    waterMaterial.roughness = roughness;
    waterMaterial.metallic = 0.0;
    float weight = materialEnvironmentWeight(waterMaterial, dot(normal, -incident)).r
                 * WATER_REFLECTION_STRENGTH;
    if (weight > 0.001) {
        vec3 direction = normalize(reflect(incident, normal));
        float reflectionDistance;
        vec4 screenReflection = traceWaterScene(
            position + normal * 0.08, direction, roughness, reflectionDistance
        );
        // 完全可靠的屏幕命中无需计算体积云和天空回退。
        vec3 environment = vec3(0.0);
        if (screenReflection.a < 1.0) {
            vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * direction);
            environment = mix(scattering.rgb, waterEnvironment(originWorld, rayWorld, surface.b, false),
                              reflectionSkyVisibility(rayWorld, roughness));
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
        float glintRoughness = sqrt(sqrt(pow4(max(WATER_ROUGHNESS * 0.55, 0.11))
                                       + min(2.0 * normalVariance, 0.035)));
        result += waterDirectSpecular(normal, position, glintRoughness) * directVisibility
                * WATER_REFLECTION_STRENGTH * WATER_SPECULAR_STRENGTH * coherence;
    }
    result = applyFog(result, length(position));
    return result;
}

#endif
