/* 水下光学合成。水上景物随水面波浪扭动，水下前景保持原坐标；
 * 水下几何独立接收光程衰减、模拟焦散与按深度重建的半分辨率光柱。
 */
#ifndef LIB_UNDERWATER_GLSL
#define LIB_UNDERWATER_GLSL
#include "water_effects.glsl"
#include "volume_resolution.glsl"
#include "sky_background.glsl"
#include "clouds.glsl"
#include "water_surface.glsl"
#include "screen_reflection_adaptive.glsl"
varying vec3 vUnderwaterTint;
varying vec3 vUnderwaterScatter;
#ifdef WORLD_BASE_OPTICS
varying float vUnderwaterDepth;
#define underwaterOpaqueSource colortex3
#else
#define underwaterOpaqueSource colortex6
#endif

#include "water_shafts_filter.glsl"

// 判断偏移坐标是否仍在水上景物中，只拒绝水下前景，不锁死水上物体轮廓。
bool isUnderwaterAirSample(vec2 uv, float waterHeight) {
    float depth = texture2D(depthtex1, uv).r;
    if (depth >= 0.999999) {
        return skyViewDirection(uv).y > 0.01;
    }
    vec3 position = screenToView(uv, depth);
    return viewToAbsoluteWorld(position).y > waterHeight + 0.015;
}

// 只在水下前景附近渐退偏移，水上物体与天空之间的轮廓可一起随波浪移动。
vec2 underwaterWaveUv(vec2 uv, vec2 offset, float waterHeight) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 search = offset;
    float safe = 0.0;
    float unsafe = 1.0;
    for (int index = 0; index < 6; index++) {
        float scale = index == 0 ? 1.0 : (safe + unsafe) * 0.5;
        vec2 candidate = clamp(uv + search * scale, vec2(0.001), vec2(0.999));
        if (isUnderwaterAirSample(candidate, waterHeight)) {
            safe = scale;
            if (index == 0) {
                break;
            }
        } else {
            unsafe = scale;
        }
    }
    float fade = smoothstep(0.0, 1.0, safe);
    return clamp(uv + offset * fade, 0.5 / size, 1.0 - 0.5 / size);
}

// 反射源刻意把天空留黑；水下出射必须从天空表恢复背景，并让实际几何继续遮挡它。
vec3 underwaterBackgroundColor(vec2 uv) {
    if (texture2D(depthtex1, uv).r < 0.999999) {
        return texture2D(underwaterOpaqueSource, uv).rgb;
    }
    vec3 direction = skyViewDirection(uv);
    vec4 cloud = cloudEnvironment(direction);
    return cloud.rgb + skyRadiance(direction) * (1.0 - cloud.a);
}

// 每个纹素先恢复自己的背景，再做连续插值，保留岸边轮廓和玻璃独立透明层。
vec3 sampleWaterExitColor(vec2 uv, out vec4 transparentLayer) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 weight = fract(pixel);
    vec3 sum = vec3(0.0);
    transparentLayer = vec4(0.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(base + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            vec2 sampleUv = (cell + 0.5) / size;
            float fraction = (x == 0 ? 1.0 - weight.x : weight.x)
                           * (y == 0 ? 1.0 - weight.y : weight.y);
            sum += underwaterBackgroundColor(sampleUv) * fraction;
            transparentLayer += texture2D(colortex2, sampleUv) * fraction;
        }
    }
    return sum;
}

// 全反射只查询水下场景。离屏或无命中时使用受当地照明控制的水色。
vec3 underwaterInterfaceReflection(vec3 interfaceView, vec3 direction, float waterHeight) {
    vec3 fallback = vUnderwaterScatter
        + vec3(0.004, 0.012, 0.018) * UNDERWATER_MIN_VISIBILITY;
    vec3 down = mat3(gbufferModelView) * vec3(0.0, -1.0, 0.0);
    ScreenReflectionHit hit = traceAdaptiveReflectionDetailed(underwaterOpaqueSource, depthtex1,
        interfaceView + down * 0.025, direction, 0.03, 24.0,
        min(WATER_REFLECTION_STEPS, 16), vec4(down, 0.02 - dot(down, interfaceView)));
    if (hit.coverage <= 0.0) {
        return fallback;
    }
    float depth = texture2D(depthtex1, hit.uv).r;
    vec3 world = viewToAbsoluteWorld(screenToView(hit.uv, min(depth, 0.99999)));
    if (depth >= 0.999999 || world.y > waterHeight + 0.02) {
        return fallback;
    }
    vec3 radiance = texture2D(underwaterOpaqueSource, hit.uv).rgb;
    return mix(fallback, applyUnderwaterVolume(radiance, hit.distance,
        vUnderwaterTint, vUnderwaterScatter), hit.coverage);
}

vec3 applyUnderwaterOptics(vec2 uv, float sceneDepth) {
    float eyeDepth = estimateUnderwaterDepth();
    float opaqueDepth = texture2D(depthtex1, uv).r;
    // 天空只需要方向；避免在无限远投影的 depth=1 处除以零。
    vec3 opaquePosition = screenToView(uv, opaqueDepth < 0.999999 ? opaqueDepth : 0.5);
    vec3 opaqueWorld = viewToAbsoluteWorld(opaquePosition);
    vec4 surface = readWaterSurface(colortex5, colortex1, uv);
    float path = underwaterVisiblePath(uv, opaqueDepth, surface.a, eyeDepth);
    float sceneDistance = opaqueDepth < 0.999999 ? length(opaquePosition) : far;
    vec3 rayWorld = skyViewDirection(uv);
    float waterHeight = cameraPosition.y + eyeDepth;
    float aboveGeometry = opaqueDepth >= 0.999999 ? 1.0
        : smoothstep(waterHeight + 0.015, waterHeight + 0.20, opaqueWorld.y);
    float airCoverage = smoothstep(0.02, 0.20, sceneDistance - path)
                      * smoothstep(0.01, 0.08, rayWorld.y) * aboveGeometry;
    vec3 interfaceWorld = cameraPosition + rayWorld * path;
    float footprint = max(length(dFdx(interfaceWorld.xz)), length(dFdy(interfaceWorld.xz)));
    // 优先使用原生水面写入的同一套细节法线，波峰与临界角边界一起运动。
    vec3 waveNormal = vec3(0.0, 1.0, 0.0);
#if ENABLE_WATER_WAVES == 1
    waveNormal = waterSurfaceNormal(interfaceWorld.xz, frameTimeCounter, footprint);
#endif
    // 原生法线也包含独立落雨涟漪；关闭风浪时仍保留这些界面扰动。
    if (surface.a > 0.001) {
        vec3 captured = mat3(gbufferModelViewInverse) * decodeWaterNormal(surface.xy);
        waveNormal = captured * (captured.y < 0.0 ? -1.0 : 1.0);
    }
    float cosine = clamp(dot(rayWorld, waveNormal), 0.0, 1.0);
    float discriminant = 1.0 - WATER_IOR * WATER_IOR * (1.0 - cosine * cosine);
    float edgeWidth = max(fwidth(discriminant) * 1.5, 0.008);
    float window = smoothstep(-edgeWidth, edgeWidth, discriminant);
    float reflectance = waterDielectricFresnel(cosine, WATER_IOR);
    vec3 radiance = texture2D(colortex0, uv).rgb;
    if (texture2D(colortex5, uv).a > 0.5) {
        radiance = applyTransparentLayer(underwaterBackgroundColor(uv), texture2D(colortex2, uv));
    }
    if (airCoverage > 0.001) {
        vec3 interfaceView = waterSurfacePosition(uv, surface.a > 0.001 ? surface.a : -opaquePosition.z);
        if (surface.a <= 0.001) {
            interfaceView = worldToView(interfaceWorld - cameraPosition);
        }
        vec3 reflectedDirection = mat3(gbufferModelView) * reflect(rayWorld, waveNormal);
        vec3 reflection = underwaterInterfaceReflection(interfaceView, reflectedDirection, waterHeight);
        vec3 air = reflection;
        if (window > 0.001 && discriminant > 0.0) {
            vec3 airDirection = normalize(refract(rayWorld, -waveNormal, WATER_IOR));
            vec3 sampleDirection = normalize(mix(rayWorld, airDirection, WATER_REFRACTION_STRENGTH));
            float airDistance = opaqueDepth < 0.999999 ? max(sceneDistance - path, 0.5) : 128.0;
            vec3 target = interfaceView + mat3(gbufferModelView) * sampleDirection * airDistance;
            vec4 clip = gbufferProjection * vec4(target, 1.0);
            vec2 projected = clip.xy / max(clip.w, 0.001) * 0.5 + 0.5;
            bool inside = clip.w > 0.001 && all(greaterThan(projected, vec2(0.001)))
                && all(lessThan(projected, vec2(0.999)));
            vec4 cloud = cloudEnvironment(sampleDirection);
            air = cloud.rgb + skyRadiance(sampleDirection) * (1.0 - cloud.a);
            vec2 radianceUv = uv;
            if (inside) {
                radianceUv = underwaterWaveUv(uv, projected - uv, waterHeight);
                if (texture2D(depthtex1, radianceUv).r < 0.999999) {
                    vec4 transparentLayer;
                    air = sampleWaterExitColor(radianceUv, transparentLayer);
                    air = applyTransparentLayer(air, transparentLayer);
                }
            }
#if DEBUG_VIEW == 0
            if (rainStrength > 0.001 && inside) {
                bool waterPresent = texture2D(colortex5, radianceUv).a > 0.5;
                air = applyRainOverlay(air, texture2D(colortex1, radianceUv), waterPresent);
            }
#endif
        }
        vec3 interfaceRadiance = mix(reflection, air, (1.0 - reflectance) * window);
        radiance = mix(radiance, interfaceRadiance, airCoverage);
    }
    vec3 normalWorld = waterReceiverNormal(opaqueWorld);
    if (opaqueDepth < 0.999999) {
        float skyVisibility = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
        radiance *= waterCausticGain(opaqueWorld, normalWorld,
            cameraPosition.y + eyeDepth, skyVisibility);
    }
    vec3 result = applyUnderwaterVolume(radiance, path, vUnderwaterTint, vUnderwaterScatter);
#ifndef WORLD_BASE_OPTICS
    result += sampleWaterShafts(uv, path);
#endif
    return result;
}

#endif
