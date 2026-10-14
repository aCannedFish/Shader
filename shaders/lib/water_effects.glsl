/* 柔和聚光与水下日照工具。平滑噪声模拟明暗变化，太阳折射方向决定投影；
 * 仅查询现有的不透明阴影图，不生成光子、光照贴图或额外场景数据。
 */
#ifndef LIB_WATER_EFFECTS_GLSL
#define LIB_WATER_EFFECTS_GLSL

#include "water_lighting.glsl"
#include "water_volume.glsl"

vec3 waterSunDirection() {
    return normalize(refract(-getSunDirWorld(), vec3(0.0, 1.0, 0.0), 1.0 / 1.333));
}

// 两层低频噪声使用三次插值平滑，形成宽而不规则的明暗起伏。
// 不绘制线框或窄亮边；聚光与体积光柱分别调制，避免水底出现发光条纹。
float waterFocusPattern(vec2 position) {
    vec2 drift = frameTimeCounter * vec2(0.055, -0.037);
    vec2 rotated = vec2(position.x * 0.83 + position.y * 0.56,
                        position.y * 0.83 - position.x * 0.56);
    float broad = cloudWeatherNoise(rotated * 0.42 + drift);
    float fine = cloudWeatherNoise(rotated * 0.86 - drift * 0.7 + vec2(13.7, 29.1));
    return broad * 0.68 + fine * 0.32;
}

// 在实际阴影纹素中心比较后插值，避免移动采样跨过最近邻纹素时跳变。
float filteredWaterShadow(vec2 uv, float receiver) {
    float resolution = float(shadowMapResolution);
    float texel = 1.0 / resolution;
    vec2 pixel = uv * resolution - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    float visibility = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 sampleUv = (base + vec2(float(x), float(y)) + 0.5) * texel;
            sampleUv = clamp(sampleUv, vec2(texel * 0.5), vec2(1.0 - texel * 0.5));
            float depth = texture2D(shadowtex1, sampleUv).r;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y);
            visibility += step(receiver, depth) * weight;
        }
    }
    return visibility;
}

// 聚光查询水面入射点以避免水底自阴影；散射查询体积点以保留沿途遮挡。
float waterSunVisibility(vec3 worldPosition, float softness) {
#if ENABLE_SHADOWS == 0
    return 1.0;
#else
    vec4 projected = shadowProjection * shadowModelView
                   * vec4(worldPosition - cameraPosition, 1.0);
    vec3 clip = projected.xyz / max(projected.w, EPSILON);
    vec3 coordinate = distortShadow(clip) * 0.5 + 0.5;
    if (any(lessThan(coordinate, vec3(0.0))) || any(greaterThan(coordinate, vec3(1.0)))) {
        return 0.0;
    }
    float receiver = coordinate.z - 0.00015;
    if (softness <= 0.0) {
        return filteredWaterShadow(coordinate.xy, receiver);
    }
    // 宽核的每个采样仍执行真实纹素上的双线性比较，不重新划分阴影网格。
    float distortion = (1.0 - SHADOW_MAP_BIAS) + length(clip.xy) * SHADOW_MAP_BIAS;
    float radius = softness * 0.5 * abs(shadowProjection[0][0]) / max(distortion, 0.05);
    radius = min(radius, 3.0 / float(shadowMapResolution));
    float visibility = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 offset = (vec2(float(x), float(y)) * 2.0 - 1.0) * radius;
            visibility += filteredWaterShadow(coordinate.xy + offset, receiver);
        }
    }
    return visibility * 0.25;
#endif
}

// 深度几何的导数保留水底与池壁的朝向，无需增加不透明法线附件。
vec3 waterReceiverNormal(vec3 worldPosition) {
    vec3 normal = safeNormalize(cross(dFdx(worldPosition), dFdy(worldPosition)), vec3(0.0, 1.0, 0.0));
    if (dot(normal, cameraPosition - worldPosition) < 0.0) {
        normal = -normal;
    }
    return normal;
}

float waterCausticGain(vec3 worldPosition, vec3 normalWorld, float waterHeight, float skyVisibility) {
    float depth = waterHeight - worldPosition.y;
    float sunlight = luma(getSunLightColor()) * skyVisibility * (1.0 - rainStrength * 0.8);
    if (WATER_CAUSTICS_STRENGTH <= 0.0 || depth <= 0.02 || sunlight <= 0.001) {
        return 1.0;
    }
    vec3 direction = waterSunDirection();
    vec3 entry = worldPosition - direction * (depth / max(-direction.y, 0.2));
    float facing = max(dot(normalWorld, -direction), 0.0);
    float depthFade = exp(-depth * 0.10) * (1.0 - smoothstep(18.0, 32.0, depth));
    float focus = waterFocusPattern(entry.xz) * 2.0 - 1.0;
    // 小幅重新分配亮度，既有柔和聚光也有弱暗部，不持续添加额外辐射。
    return 1.0 + focus * facing * depthFade * sunlight
         * waterSunVisibility(entry, 0.0) * WATER_CAUSTICS_STRENGTH * 0.35;
}

// 水面仅限制水内光程，不限制水上景物的可见方向，也没有临界角窗口。
float underwaterVisiblePath(vec2 uv, float opaqueDepth, float surfaceDepth, float eyeDepth) {
    vec3 geometry = screenToView(uv, opaqueDepth);
    float distance = opaqueDepth < 0.999999 ? length(geometry) : far;
    if (surfaceDepth > 0.001 && (opaqueDepth >= 0.999999 || -geometry.z > surfaceDepth + 0.015)) {
        vec3 surfacePosition = waterSurfacePosition(uv, surfaceDepth);
        if (viewToAbsoluteWorld(surfacePosition).y > cameraPosition.y + 0.02) {
            return min(distance, length(surfacePosition));
        }
    }
    vec3 ray = normalize(mat3(gbufferModelViewInverse) * screenToView(uv, 0.5));
    if (ray.y > 0.001 && eyeDepth > 0.02) {
        distance = min(distance, eyeDepth / ray.y);
    }
    return distance;
}

// 八个固定样本积累沿视线的散射，入射点沿折射后的阳光方向保持一致。
vec3 integrateWaterShafts(vec2 uv, float pathLength, float eyeDepth) {
    float skyLevel = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
    vec3 sunlight = getSunLightColor();
    if (UNDERWATER_SHAFT_STRENGTH <= 0.0 || skyLevel <= 0.03 || luma(sunlight) <= 0.001) {
        return vec3(0.0);
    }
    vec3 ray = normalize(mat3(gbufferModelViewInverse) * screenToView(uv, 0.5));
    vec3 direction = waterSunDirection();
    float stepLength = min(pathLength, 48.0) / 8.0;
    // 无时间降噪时采用固定中点，避免随机积分位置形成显眼的像素颗粒。
    const float jitter = 0.5;
    float waterHeight = cameraPosition.y + eyeDepth;
    vec3 extinction = waterExtinctionCoefficient() * UNDERWATER_DENSITY * FOG_DENSITY;
    vec3 sum = vec3(0.0);
    for (int index = 0; index < 8; index++) {
        float distance = (float(index) + jitter) * stepLength;
        vec3 position = cameraPosition + ray * distance;
        float depth = max(waterHeight - position.y, 0.0);
        vec3 entry = position - direction * (depth / max(-direction.y, 0.2));
        float focus = waterFocusPattern(entry.xz);
        focus = focus * focus * focus * 2.5;
        float visibility = waterSunVisibility(position, 0.14);
        float depthFade = exp(-depth * 0.065 * UNDERWATER_DEPTH_DIMMING);
        sum += exp(-extinction * distance) * focus * visibility * depthFade * stepLength;
    }
    float forwardPhase = 0.30 + 0.70 * pow(max(dot(ray, -direction), 0.0), 4.0);
    float scattering = 0.015 + WATER_TURBIDITY * 0.5;
    return sum * sunlight * scattering * forwardPhase * UNDERWATER_SHAFT_STRENGTH
         * smoothstep(0.03, 0.5, skyLevel) * (1.0 - rainStrength * 0.8);
}

#endif
