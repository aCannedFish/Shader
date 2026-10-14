/* 水下光学合成。水面按视角混合粗糙透射与水内反射，形成可辨识的界面；
 * 水下几何独立接收光程衰减、模拟焦散与按深度重建的半分辨率光柱。
 */
#ifndef LIB_UNDERWATER_GLSL
#define LIB_UNDERWATER_GLSL
#include "water_effects.glsl"

float estimateUnderwaterDepth() {
    return texture2D(colortex4, vec2(0.5) / vec2(viewWidth, viewHeight)).a;
}

// alpha 保存积分终点，拒绝跨越近处遮挡物的散射，首个元数据纹素不参与重建。
vec3 sampleWaterShafts(vec2 uv, float pathLength) {
    if (UNDERWATER_SHAFT_STRENGTH <= 0.0) {
        return vec3(0.0);
    }
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
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

// 水上图像的轻度粗糙透射过滤；拒绝位于水面前方的采样，保护水下轮廓。
vec3 filterWaterExit(vec2 uv, float interfaceDepth, float radius) {
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 offset = vec2(float(x), float(y)) * radius * texel;
            vec2 sampleUv = clamp(uv + offset, texel, 1.0 - texel);
            float depth = texture2D(depthtex1, sampleUv).r;
            float linearDepth = -screenToView(sampleUv, depth).z;
            float weight = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
            weight *= smoothstep(interfaceDepth - 0.02, interfaceDepth + 0.15, linearDepth);
            sum += texture2D(colortex6, sampleUv).rgb * weight;
            total += weight;
        }
    }
    return total > EPSILON ? sum / total : texture2D(colortex6, uv).rgb;
}

// 接近轮廓前平滑减弱波动，避免直接夹到边缘纹素形成跳动的锐利切线。
vec2 underwaterWaveUv(vec2 uv, vec2 offset, float referenceDepth) {
    float pixelLength = length(offset * vec2(viewWidth, viewHeight));
    offset *= min(1.0, 1.25 / max(pixelLength, 0.001));
    vec2 searchOffset = offset * 2.0;
    float safe = 0.0;
    float unsafe = 1.0;
    float tolerance = max(0.15, referenceDepth * 0.02);
    for (int iteration = 0; iteration < 6; iteration++) {
        float scale = iteration == 0 ? 1.0 : (safe + unsafe) * 0.5;
        vec2 candidate = clamp(uv + searchOffset * scale, vec2(0.001), vec2(0.999));
        float depth = texture2D(depthtex1, candidate).r;
        float difference = abs(-screenToView(candidate, depth).z - referenceDepth);
        if (difference < tolerance) {
            safe = scale;
            if (iteration == 0) {
                break;
            }
        } else {
            unsafe = scale;
        }
    }
    float margin = 0.35 / max(length(searchOffset * vec2(viewWidth, viewHeight)), 1.0);
    float fade = safe >= 1.0 ? 1.0 : smoothstep(0.0, 1.0, max(safe - margin, 0.0));
    return clamp(uv + offset * fade, vec2(0.001), vec2(0.999));
}

// 水面下侧的宽反射瓣以当地水体辐射近似；环境与局部光随场景变化。
// 宽瓣不解析单个水内物体，避免薄轮廓的屏幕空间命中在帧间跳变。
vec3 underwaterSurfaceReflection(vec2 uv, vec3 rayWorld, vec3 normalWorld, float eyeDepth) {
    vec3 direction = reflect(rayWorld, normalWorld);
    vec3 environment = underwaterScatterColor(eyeDepth);
    vec3 localSurface = texture2D(colortex7, uv).rgb;
    float facing = 0.85 + 0.15 * abs(direction.y);
    return mix(environment, localSurface, 0.12) * facing;
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
    float airCoverage = smoothstep(0.02, 0.20, sceneDistance - path)
                      * smoothstep(0.01, 0.08, rayWorld.y);
    vec3 interfaceWorld = cameraPosition + rayWorld * path;
    // 相位锚定水面交点；岸上物体深度和轮廓不再改变波浪相位。
    vec3 waveNormal = vec3(0.0, 1.0, 0.0);
#if ENABLE_WATER_WAVES == 1
    waveNormal = getWaterWaveNormal(interfaceWorld.xz, frameTimeCounter);
#endif
    vec2 radianceUv = uv;
    if (WATER_REFRACTION_STRENGTH > 0.0 && airCoverage > 0.001) {
        vec3 wave = waveNormal - vec3(0.0, 1.0, 0.0);
        vec2 offset = (mat3(gbufferModelView) * wave).xy
                    * 0.008 * WATER_REFRACTION_STRENGTH * airCoverage;
        radianceUv = underwaterWaveUv(uv, offset, -opaquePosition.z);
    }
    vec3 radiance = texture2D(colortex0, uv).rgb;
    if (texture2D(colortex7, uv).a > 0.0) {
        radiance = texture2D(colortex6, uv).rgb;
    }
    if (airCoverage > 0.001) {
        float cosine = clamp(dot(waveNormal, rayWorld), 0.0, 1.0);
        float fresnel = waterFresnel(cosine);
        float radius = (0.65 + 3.0 * WATER_ROUGHNESS + 1.5 * fresnel)
                     * min(viewWidth, viewHeight) / 1080.0;
        vec3 air = filterWaterExit(radianceUv, path * max(-normalize(opaquePosition).z, 0.0), radius);
        // 先调节透射，再混合水面自身的反射；水下前景不进入这条路径。
        float veil = WATER_SURFACE_OPACITY + WATER_ROUGHNESS * 0.25;
        air = mix(air, underwaterScatterColor(eyeDepth), clamp(veil, 0.0, 0.25));
        float grazing = 1.0 - smoothstep(0.30, 0.85, cosine);
        float reflectionWeight = mix(fresnel, 0.88, grazing);
        vec3 reflected = underwaterSurfaceReflection(uv, rayWorld, waveNormal, eyeDepth);
        vec3 interfaceColor = mix(air, reflected, reflectionWeight);
        radiance = mix(radiance, interfaceColor, airCoverage);
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
