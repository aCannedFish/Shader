/* 水下光学合成。水上景物随水面波浪扭动，水下前景保持原坐标；
 * 水下几何独立接收光程衰减、模拟焦散与按深度重建的半分辨率光柱。
 */
#ifndef LIB_UNDERWATER_GLSL
#define LIB_UNDERWATER_GLSL
#include "water_effects.glsl"
#include "volume_resolution.glsl"

float estimateUnderwaterDepth() {
    return texture2D(colortex4, vec2(0.5) / vec2(viewWidth, viewHeight)).a;
}

// alpha 保存积分终点，拒绝跨越近处遮挡物的散射，首个元数据纹素不参与重建。
vec3 sampleWaterShafts(vec2 uv, float pathLength) {
    if (UNDERWATER_SHAFT_STRENGTH <= 0.0) {
        return vec3(0.0);
    }
    vec2 size = volumeSize();
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    float distance = min(pathLength, 48.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(base + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            if (cell.x < 0.5 && cell.y < 0.5) {
                continue;
            }
            vec4 fieldSample = texture2D(colortex4, (cell + 0.5) / vec2(viewWidth, viewHeight));
            float spatial = (x == 0 ? 1.0 - fraction.x : fraction.x)
                          * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = spatial * exp(-abs(fieldSample.a - distance) / max(distance * 0.08, 0.15));
            sum += fieldSample.rgb * weight;
            total += weight;
        }
    }
    return total > EPSILON ? sum / total : vec3(0.0);
}

// 判断偏移坐标是否仍在水上景物中，只拒绝水下前景，不锁死水上物体轮廓。
bool isUnderwaterAirSample(vec2 uv, float waterHeight) {
    float depth = texture2D(depthtex1, uv).r;
    vec3 position = screenToView(uv, depth);
    if (depth >= 0.999999) {
        return (mat3(gbufferModelViewInverse) * normalize(position)).y > 0.01;
    }
    return viewToAbsoluteWorld(position).y > waterHeight + 0.015;
}

// 只在水下前景附近渐退偏移，水上物体与天空之间的轮廓可一起随波浪移动。
vec2 underwaterWaveUv(vec2 uv, vec2 offset, float waterHeight) {
    vec2 size = vec2(viewWidth, viewHeight);
    float limit = 16.0 * min(viewWidth, viewHeight) / 1080.0;
    offset *= min(1.0, limit / max(length(offset * size), 0.001));
    vec2 search = offset * 1.5;
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

// 明确在纹素中心插值，保证慢速波浪产生连续的亚像素移动。
vec3 sampleWaterExitColor(vec2 uv) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 weight = fract(pixel);
    vec3 sum = vec3(0.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(base + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            float fraction = (x == 0 ? 1.0 - weight.x : weight.x)
                           * (y == 0 ? 1.0 - weight.y : weight.y);
            sum += texture2D(colortex6, (cell + 0.5) / size).rgb * fraction;
        }
    }
    return sum;
}

vec3 applyUnderwaterOptics(vec2 uv, float sceneDepth) {
    float eyeDepth = estimateUnderwaterDepth();
    float opaqueDepth = texture2D(depthtex1, uv).r;
    vec3 opaquePosition = screenToView(uv, opaqueDepth);
    vec3 opaqueWorld = viewToAbsoluteWorld(opaquePosition);
    vec4 surface = texture2D(colortex5, uv);
    float path = underwaterVisiblePath(uv, opaqueDepth, surface.a, eyeDepth);
    float sceneDistance = opaqueDepth < 0.999999 ? length(opaquePosition) : far;
    vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * normalize(opaquePosition));
    float waterHeight = cameraPosition.y + eyeDepth;
    float aboveGeometry = opaqueDepth >= 0.999999 ? 1.0
        : smoothstep(waterHeight + 0.015, waterHeight + 0.20, opaqueWorld.y);
    float airCoverage = smoothstep(0.02, 0.20, sceneDistance - path)
                      * smoothstep(0.01, 0.08, rayWorld.y) * aboveGeometry;
    vec3 interfaceWorld = cameraPosition + rayWorld * path;
    // 相位锚定水面交点；岸上物体深度和轮廓不再改变波浪相位。
    vec3 waveNormal = vec3(0.0, 1.0, 0.0);
#if ENABLE_WATER_WAVES == 1
    waveNormal = getWaterWaveNormal(interfaceWorld.xz, frameTimeCounter);
#endif
    vec2 radianceUv = uv;
    if (WATER_REFRACTION_STRENGTH > 0.0 && airCoverage > 0.001) {
        vec3 wave = waveNormal - vec3(0.0, 1.0, 0.0);
        // 低频摆动叠加波浪法线，使水上景物整体随水面明显晃动，夜间也能凭运动分辨。
        vec2 sway = vec2(sin(dot(interfaceWorld.xz, vec2(0.71, 0.37)) + frameTimeCounter * 1.9),
                         cos(dot(interfaceWorld.xz, vec2(-0.29, 0.83)) + frameTimeCounter * 1.6));
        vec2 offset = ((mat3(gbufferModelView) * wave).xy * 0.075 + sway * 0.0045)
                    * WATER_REFRACTION_STRENGTH * airCoverage;
        radianceUv = underwaterWaveUv(uv, offset, waterHeight);
    }
    vec3 radiance = texture2D(colortex0, uv).rgb;
    if (texture2D(colortex7, uv).a > 0.0) {
        radiance = texture2D(colortex6, uv).rgb;
    }
    if (airCoverage > 0.001) {
        vec3 air = sampleWaterExitColor(radianceUv);
        // 天空像素在水下同样透过水面看到云，云环境由 deferred 预先构建。
        if (texture2D(depthtex1, radianceUv).r >= 0.999999) {
            vec4 cloud = cloudEnvironment(skyViewDirection(radianceUv));
            air = cloud.rgb + air * (1.0 - cloud.a);
        }
        radiance = mix(radiance, air, airCoverage);
    }
    vec3 normalWorld = waterReceiverNormal(opaqueWorld);
    if (opaqueDepth < 0.999999) {
        float skyVisibility = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
        radiance *= waterCausticGain(opaqueWorld, normalWorld,
            cameraPosition.y + eyeDepth, skyVisibility);
    }
    return applyUnderwaterVolume(radiance, path, eyeDepth) + sampleWaterShafts(uv, path);
}

#endif
