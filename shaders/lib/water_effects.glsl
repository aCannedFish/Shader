/* 柔和聚光与水下日照工具。变形胞元模拟聚光纹理，太阳折射方向决定投影；
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
        return filteredShadowVisibility(shadowtex1, coordinate.xy, receiver);
    }
    // 宽核的每个采样仍执行真实纹素上的双线性比较，不重新划分阴影网格。
    float distortion = (1.0 - SHADOW_MAP_BIAS) + length(clip.xy) * SHADOW_MAP_BIAS;
    float radius = softness * 0.5 * abs(shadowProjection[0][0]) / max(distortion, 0.05);
    radius = min(radius, 3.0 / shadowTextureResolution());
    float visibility = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 offset = (vec2(float(x), float(y)) * 2.0 - 1.0) * radius;
            visibility += filteredShadowVisibility(shadowtex1, coordinate.xy + offset, receiver);
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

// 流动胞元的间隙形成不规则聚光网；高斯横截面保留纹理，又避免硬亮边。
float waterCausticRidges(vec2 position, float width) {
    vec2 cell = floor(position);
    vec2 local = fract(position);
    float nearest = 8.0;
    float second = 8.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 neighbour = vec2(float(x), float(y));
            vec2 seed = vec2(cloudCellHash(cell + neighbour),
                             cloudCellHash(cell + neighbour + 37.2));
            vec2 point = 0.5 + 0.28 * sin(seed * TAU + frameTimeCounter * 0.45);
            vec2 delta = neighbour + point - local;
            float distance = dot(delta, delta);
            if (distance < nearest) {
                second = nearest;
                nearest = distance;
            } else {
                second = min(second, distance);
            }
        }
    }
    float gap = (sqrt(second) - sqrt(nearest)) * 0.5;
    return exp(-0.5 * square(gap / width));
}

// 两个尺度叠加保留聚光网细节；只扩散亮边，不模糊整个图案或水底颜色。
float waterCausticPattern(vec2 position, float depth, float footprint) {
    float time = frameTimeCounter * 0.35;
    vec2 warp = sin(vec2(dot(position, vec2(0.85, 0.52)),
                         dot(position, vec2(-0.46, 0.97))) + vec2(time, -time)) * 0.35;
    vec2 p = position + warp + getWaterWaveNormal(position, frameTimeCounter).xz * 1.4;
    float width = 0.055 + min(depth, 12.0) * 0.003 + WATER_TURBIDITY * 0.15;
    float filteredWidth = sqrt(width * width + footprint * footprint);
    float broad = waterCausticRidges(p * 1.1, filteredWidth * 1.1);
    float fine = waterCausticRidges(p * 1.76 + vec2(23.7, 9.2), filteredWidth * 1.76);
    float focus = (broad * 0.75 + fine * 0.25) * 2.8 - 0.45;
    return focus * width / filteredWidth * (1.0 - smoothstep(0.15, 0.50, footprint));
}

float waterCausticGain(vec3 worldPosition, vec3 normalWorld, float waterHeight, float skyVisibility) {
    float depth = waterHeight - worldPosition.y;
    vec3 direction = waterSunDirection();
    vec3 entry = worldPosition - direction * (max(depth, 0.0) / max(-direction.y, 0.2));
    // 导数在提前退出之前计算，保持相邻片元对的足迹有效；昂贵的胞元纹理
    // 等确认日照、朝向、深度与入射遮挡有效后再生成。
    float footprint = length(fwidth(entry.xz)) * 0.5;
    float sunlight = luma(getSunLightColor()) * skyVisibility * (1.0 - rainStrength * 0.8);
    if (WATER_CAUSTICS_STRENGTH <= 0.0 || depth <= 0.02 || depth >= 32.0 || sunlight <= 0.001) {
        return 1.0;
    }
    float facing = max(dot(normalWorld, -direction), 0.0);
    if (facing <= 0.0 || footprint >= 0.50) {
        return 1.0;
    }
    float depthFade = exp(-depth * 0.10) * (1.0 - smoothstep(18.0, 32.0, depth));
    float visibility = waterSunVisibility(entry, 0.0);
    if (visibility <= 0.0) {
        return 1.0;
    }
    float focus = waterCausticPattern(entry.xz, depth, footprint);
    return max(1.0 + focus * facing * depthFade * sunlight * visibility
               * WATER_CAUSTICS_STRENGTH * 0.90, 0.65);
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
    float stepLength = min(pathLength, 48.0) / float(WATER_SHAFT_STEPS);
    // 无时间降噪时采用固定中点，避免随机积分位置形成显眼的像素颗粒。
    const float jitter = 0.5;
    float waterHeight = cameraPosition.y + eyeDepth;
    vec3 extinction = waterExtinctionCoefficient() * UNDERWATER_DENSITY * FOG_DENSITY;
    vec3 sum = vec3(0.0);
    for (int index = 0; index < WATER_SHAFT_STEPS; index++) {
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
