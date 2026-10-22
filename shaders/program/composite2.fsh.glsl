/* composite2.fsh: sky, water optics and depth-aware volume reconstruction. */
/* RENDERTARGETS: 0 */
const bool colortex6MipmapEnabled = true;
#include "../lib/clouds.glsl"
#include "../lib/sky_background.glsl"
#include "../lib/water_reflection.glsl"
uniform sampler2D colortex0;
uniform sampler2D colortex4;
uniform sampler2D depthtex0;
#include "../lib/underwater.glsl"
#include "../lib/atmosphere_media.glsl"
#include "../lib/volume_resolution.glsl"

// Neighbour depths reject volume samples from the other side of a foreground
// silhouette. No temporal history is needed, so captures remain deterministic.
vec4 upsampleClouds(vec2 uv, float distance) {
    vec3 ray = getCloudRayWorld(uv);
    float entry;
    float exit;
    if (isEyeInWater == 1 || (!airScatteringEnabled() && !localAtmosphereEnabled()
        && !cloudRayInterval(cameraPosition, ray, distance, entry, exit))) {
        return vec4(0.0);
    }
    vec2 size = volumeSize();
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    vec4 sum = vec4(0.0);
    float total = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 sampleUv = clamp((base + vec2(float(x), float(y)) + 0.5) / size,
                                  0.5 / size, 1.0 - 0.5 / size);
            float depth = texture2D(depthtex1, sampleUv).r;
            float neighbourDistance = depth < 0.999999 ? length(screenToView(sampleUv, depth)) : CLOUD_DISTANCE;
            float surface = readWaterSurface(colortex5, colortex1, sampleUv).a;
            if (surface > 0.001) {
                neighbourDistance = min(neighbourDistance, length(waterSurfacePosition(sampleUv, surface)));
            }
            float spatial = (x == 0 ? 1.0 - fraction.x : fraction.x)
                          * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = spatial * exp(-abs(neighbourDistance - distance) / max(distance * 0.10, 0.5));
            sum += texture2D(colortex4, sampleUv * size / vec2(viewWidth, viewHeight)) * weight;
            total += weight;
        }
    }
    return total > 0.00001 ? sum / total : vec4(0.0);
}

void main() {
    vec2 screenCoord = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    float depth = texture2D(depthtex0, screenCoord).r;
    // 入水状态是整帧常量。水下合成本身负责天空、深度与水面采样，无需在此
    // 预先计算随后立即被覆盖的天空/水面反射，也不读取空气体积场。
    if (isEyeInWater == 1) {
        gl_FragData[0] = vec4(applyUnderwaterOptics(screenCoord, depth), 1.0);
        return;
    }
    vec4 scene = texture2D(colortex0, screenCoord);
    vec3 color = scene.rgb;
    float backgroundTransmission = rainStrength > 0.001 ? clamp(scene.a, 0.0, 1.0) : 1.0;
    float sceneDistance = depth < 0.999999 ? length(screenToView(screenCoord, depth)) : CLOUD_DISTANCE;
    vec4 waterSurface = readWaterSurface(colortex5, colortex1, screenCoord);
    float waterDepth = waterSurface.a;
    // 在水面分支前求法线变化率，保证轮廓附近的屏幕导数也有定义。
    vec3 waterNormal = decodeWaterNormal(waterSurface.xy);
    vec3 normalDx = dFdx(waterNormal);
    vec3 normalDy = dFdy(waterNormal);
    float waterCoverage = step(0.001, waterDepth);
    float sameX = 1.0 - step(0.5, abs(dFdx(waterCoverage)));
    float sameY = 1.0 - step(0.5, abs(dFdy(waterCoverage)));
    float normalVariance = 0.15 * (dot(normalDx, normalDx) * sameX + dot(normalDy, normalDy) * sameY);
    if (waterDepth > 0.001 && isEyeInWater == 0) {
        vec3 waterPosition = waterSurfacePosition(screenCoord, waterDepth);
        sceneDistance = min(sceneDistance, length(waterPosition));
        vec4 transparentLayer = texture2D(colortex2, screenCoord);
        bool inFront = transparentLayerInFront(-screenToView(screenCoord, depth).z,
                                               waterDepth, transparentLayer.a);
        color = applyWaterReflection(color, screenCoord, normalVariance,
                                     inFront ? vec4(0.0) : transparentLayer);
        if (inFront) {
            color = applyTransparentLayer(color, transparentLayer);
        }
#if DEBUG_VIEW == 0
        // Water optics rebuild the background; restore visible rain afterwards.
        color = applyRainOverlay(color, texture2D(colortex1, screenCoord), true);
#endif
#if DEBUG_VIEW != 0
        backgroundTransmission = 1.0;
#endif
    } else if (backgroundTransmission >= 0.99999) {
        // 天空已经在 deferred1 填好；雨丝覆盖处保留混合结果，避免再次覆盖雨幕。
        color = fillSkyBackground(color, screenCoord, depth);
    }
    if (depth < 0.999999 || waterDepth > 0.001) {
        // 雨丝自身按距离淡出，雾色差只修正仍可见的背景，避免远处雨丝发黄。
        color = correctSkyFog(color, screenCoord, sceneDistance, backgroundTransmission);
    }
    // Glass transmits the medium behind it. Opaque depth guides all air fields;
    // the explicit water interface still clips them at the air/water boundary.
    float opaqueDepth = texture2D(depthtex1, screenCoord).r;
    float volumeDistance = opaqueDepth < 0.999999
        ? length(screenToView(screenCoord, opaqueDepth)) : CLOUD_DISTANCE;
    if (waterDepth > 0.001) {
        volumeDistance = min(volumeDistance, length(waterSurfacePosition(screenCoord, waterDepth)));
    }
    vec4 cloud = upsampleClouds(screenCoord, volumeDistance);
    color = cloud.rgb + color * (1.0 - cloud.a);
    gl_FragData[0] = vec4(color, 1.0);
}
