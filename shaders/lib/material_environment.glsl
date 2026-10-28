/* Low-frequency reflected radiance shared by forward shading and SSR.
 * A complete base radiance prevents another metal surface from appearing black
 * in the first reflection bounce, before the screen reflection pass runs.
 */
#ifndef LIB_MATERIAL_ENVIRONMENT_GLSL
#define LIB_MATERIAL_ENVIRONMENT_GLSL
#include "atmosphere.glsl"
#include "lightmap.glsl"

// 离屏反射向下半球时没有天空可见度。粗糙度给地平线一个有限过渡宽度，
// 避免屏幕反射失效后把本应反射地面的方向突然替换成明亮天空。
float reflectionSkyVisibility(vec3 directionWorld, float roughness) {
    float width = max(0.01, roughness * 0.15);
    return smoothstep(-width, width, directionWorld.y);
}

// 倒影里的天空按当地天光可见度衰减。屏幕外的树冠、屋檐无法被屏幕空间光线
// 发现，光照贴图是唯一的线索；曲线比漫反射用的更陡（参考 Sildur 的
// (lm*1.2-0.15)^2），树荫、屋檐下的水面与积水不再反射整片明亮天空。
float reflectionSkyLightWeight(float skyLevel) {
    float weight = clamp(skyLevel * 1.2 - 0.15, 0.0, 1.0);
    return weight * weight;
}

// The native light field supplies low-frequency local radiance when reflected
// geometry is off screen. It never fabricates an unoccluded solar highlight.
vec3 materialAmbientEnvironment(vec3 directionWorld, vec2 lmCoord) {
#if SIMPLE_DIMENSION != 0
    vec3 environment = dimensionAmbient(directionWorld) * AMBIENT_STRENGTH;
#if SIMPLE_DIMENSION == 1
    environment = mix(environment, dimensionBackground(directionWorld) * 1.8,
                      END_ATMOSPHERE * 0.65 * smoothstep(-0.2, 0.5, directionWorld.y));
#endif
    return environment + blockLightRadiance(lmCoord);
#else
    float sky = smoothstep(0.02, 0.95, lightmapLevel(lmCoord.y));
    // 隐藏面的环境回退与可见天空采用同一天气响应，阴雨时不残留晴天蓝色。
    vec3 environment = weatherSkyRadiance(toLinearSpace(skyColor)) * mix(0.15, 0.65, skyDaylight())
                     * mix(0.30, 1.0, directionWorld.y * 0.5 + 0.5);
    return environment * sky + blockLightRadiance(lmCoord);
#endif
}
#endif
