/* 近地面日光的单次体积散射。真实阴影限制入射光，Beer-Lambert 同时约束
 * 透射损失与散射增益；复用半分辨率场，不使用屏幕径向模糊或时间随机噪声。
 */
#ifndef LIB_AIR_SCATTERING_GLSL
#define LIB_AIR_SCATTERING_GLSL

#include "water_lighting.glsl"

bool airScatteringEnabled() {
#if ENABLE_SHADOWS == 0
    return false;
#else
    return isEyeInWater == 0 && AIR_SCATTER_STRENGTH > 0.0
        && SKY_HAZE > 0.0 && FOG_DENSITY > 0.0 && getSunHeight() > 0.0;
#endif
}

// 相机朝向太阳时以气溶胶前向散射为主，较弱的分子项覆盖侧向观察。
float airScatteringPhase(float cosine) {
    const float g = 0.65;
    float mie = (1.0 - g * g)
              / (4.0 * PI * pow(1.0 + g * g - 2.0 * g * cosine, 1.5));
    float rayleigh = 3.0 * (1.0 + cosine * cosine) / (16.0 * PI);
    return mie * 0.85 + rayleigh * 0.15;
}

// 仅接受不透明阴影覆盖内的样本；覆盖外不凭空补日照。
float airSunVisibility(vec3 relativePosition) {
    vec4 projected = shadowProjection * shadowModelView * vec4(relativePosition, 1.0);
    vec3 coordinate = distortShadow(projected.xyz / max(projected.w, EPSILON)) * 0.5 + 0.5;
    if (any(lessThan(coordinate, vec3(0.0))) || any(greaterThan(coordinate, vec3(1.0)))) {
        return 0.0;
    }
    return filteredShadowVisibility(shadowtex1, coordinate.xy, coordinate.z - 0.00015);
}

// 空间连续的颗粒浓度场。复用三维噪声，只形成缓慢漂移的空气密度起伏。
float airParticleDensity(vec3 worldPosition) {
    vec3 drift = frameTimeCounter * vec3(0.025, 0.0, 0.009);
    float particles = cloudVolumeNoise((worldPosition - drift) / 256.0).r;
    float variation = mix(0.55, 1.45, smoothstep(0.20, 0.80, particles));
    float altitude = exp(-max(worldPosition.y - 64.0, 0.0) / 120.0);
    return variation * altitude;
}

// 三十二个固定距离区间，遇到几何只截短最后一段，避免重排所有样本造成跳动。
// RGB 是沿途真实受光介质的预乘入散射，alpha 是同一介质的光学不透明度。
vec4 integrateAirScattering(vec2 uv, float sceneDistance) {
    if (!airScatteringEnabled()) {
        return vec4(0.0);
    }
    vec3 sun = getSunDirWorld();
    if (dot(normalize(sunPosition), getLightDirView()) < 0.95) {
        return vec4(0.0);
    }
    vec3 ray = normalize(mat3(gbufferModelViewInverse) * screenToView(uv, 0.5));
    float range = min(64.0, shadowDistance * 0.8);
    float limit = min(sceneDistance, range);
    float lowSun = 1.0 - smoothstep(0.10, 0.65, sun.y);
    float coefficient = mix(0.0012, 0.0090, lowSun) * SKY_HAZE * FOG_DENSITY
                      * AIR_SCATTER_STRENGTH * smoothstep(0.0, 0.08, sun.y);
    coefficient = min(coefficient, 0.012);
    // 表面使用 albedo * 日光 * NdotL，已隐含 Lambert 的 1/PI。
    // 相函数以每球面度归一化，介质计算须先恢复入射照度。
    // 方向光的体积贡献单独校准，显出遮挡光束而不继续提高全局消光。
    vec3 sunlight = getSunLightColor() * PI * 1.5 * (1.0 - rainStrength * 0.85);
    // 极低高度的云影投影会退化，平滑衔接其地平线回退，避免日落时亮度跳变。
    float cloudNear = cloudProjectedShadow(cameraPosition, sun);
    float cloudMiddle = cloudProjectedShadow(cameraPosition + ray * limit * 0.5, sun);
    float cloudFar = cloudProjectedShadow(cameraPosition + ray * limit, sun);
    float phase = airScatteringPhase(dot(ray, sun));
    vec3 radiance = vec3(0.0);
    float transmission = 1.0;
    float previous = 0.0;
    for (int index = 0; index < 32; index++) {
        float u = float(index + 1) / 32.0;
        float next = min(u * u * range, limit);
        if (next <= previous) {
            break;
        }
        float distance = (previous + next) * 0.5;
        vec3 relative = ray * distance;
        float density = airParticleDensity(cameraPosition + relative);
        density *= 1.0 - smoothstep(range * 0.75, range, distance);
        // 远景已有加载距离雾，在其接管前渐退近地面介质。
        density *= 1.0 - smoothstep(far * 0.40, far * 0.65, distance);
        float segment = exp(-coefficient * density * (next - previous));
        float visibility = airSunVisibility(relative);
        float cloudPosition = distance / max(limit, EPSILON);
        float cloudVisibility = cloudPosition < 0.5
            ? mix(cloudNear, cloudMiddle, cloudPosition * 2.0)
            : mix(cloudMiddle, cloudFar, cloudPosition * 2.0 - 1.0);
        cloudVisibility = mix(1.0, cloudVisibility, smoothstep(0.04, 0.10, sun.y));
        radiance += transmission * sunlight * phase * visibility * cloudVisibility
                  * 0.90 * (1.0 - segment);
        transmission *= segment;
        previous = next;
    }
    return vec4(radiance, 1.0 - transmission);
}

#endif
