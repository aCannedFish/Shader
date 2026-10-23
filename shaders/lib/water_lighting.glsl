/* 水面局部光照与 GGX 高光；只供片元阶段使用。 */
#ifndef LIB_WATER_LIGHTING_GLSL
#define LIB_WATER_LIGHTING_GLSL

#include "lighting.glsl"
#include "space.glsl"
#include "water.glsl"
#include "shadow_filter.glsl"

// shadowtex1 不含半透明水体，避免水面把自身遮成黑色。

// Minecraft 光照坐标的端点是 8/256 与 248/256，对应等级 0 与 15。
float waterSkyLevel(float lightmapY) {
    return clamp((lightmapY - 0.03125) / 0.9375, 0.0, 1.0);
}

float waterSkyVisibility(float lightmapY) {
    return smoothstep(0.02, 0.95, waterSkyLevel(lightmapY));
}

// 水色直接定义为线性散射反照率，避免较暗的显示色再经 gamma 压缩后接近黑色。
// 群系只保留少量色相差异；实际辐射仍由当地环境光和直射光决定。
// 真实水体的散射很弱，看到的颜色主要来自倒影：这里采用偏暗、饱和度较低的青蓝，
// 让晴天显出天空的蓝、雨天显灰、夜晚趋黑，而不是始终是一层浓重的蓝色。
vec3 waterScatteringAlbedo(vec3 biomeTint) {
    vec3 biome = toLinearSpace(biomeTint);
    float maximum = max(max(biome.r, biome.g), max(biome.b, EPSILON));
    vec3 hue = biome / maximum;
    vec3 palette = mix(vec3(0.012, 0.045, 0.055), vec3(0.026, 0.090, 0.105),
                       WATER_COLOR_LIGHTNESS);
    return palette * mix(vec3(1.0), hue, 0.15);
}

// 保留距离淡出与接收面斜率补偿，水体仅接收不透明物体投出的阴影。
float waterOpaqueShadow(vec4 shadowClipPos, vec3 normalView, float viewDistance) {
    return sampleSoftDirectionalShadow(shadowtex1, shadowClipPos, normalView, viewDistance);
}


// 水体底色以间接光为主，日月直射主要由独立高光表现，避免散射水色过亮。
// 当地光照贴图包含方块光，封闭水域仍由当地照明决定亮度。
vec3 waterDiffuse(vec3 albedo, vec3 normalView, vec2 lmCoord,
                  float directVisibility, vec3 viewPosition) {
    vec3 ambient = surfaceAmbientAt(lmCoord, 1.0, normalView, viewPosition);
#if SIMPLE_DIMENSION != 0
    return albedo * ambient;
#endif
    float sunCosine = max(dot(normalView, normalize(sunPosition)), 0.0);
    float moonCosine = max(dot(normalView, normalize(moonPosition)), 0.0);
    vec3 direct = getSunLightColor() * sunCosine + getMoonLightColor() * moonCosine;
    return albedo * (ambient + direct * directVisibility * 0.12);
}

// GGX 分布与 Smith 遮蔽近似，太阳/月亮都使用水的 Fresnel，避免任意白色亮斑。
vec3 waterLightSpecular(vec3 normal, vec3 view, vec3 light, vec3 radiance, float roughness) {
    float nl = max(dot(normal, light), 0.0);
    // 日月中的无贡献光源，以及朝向背离光源的波面，无需执行 GGX 的后续运算。
    if (nl <= 0.0 || !any(greaterThan(radiance, vec3(0.0)))) {
        return vec3(0.0);
    }
    vec3 halfVector = safeNormalize(view + light, normal);
    float nv = max(dot(normal, view), 0.001);
    float nh = max(dot(normal, halfVector), 0.0);
    float vh = max(dot(view, halfVector), 0.0);
    float alpha = max(roughness * roughness, 0.006);
    float alphaSquared = alpha * alpha;
    float denominator = nh * nh * (alphaSquared - 1.0) + 1.0;
    float distribution = alphaSquared / (PI * denominator * denominator);
    float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    float geometryV = nv / (nv * (1.0 - k) + k);
    float geometryL = nl / (nl * (1.0 - k) + k);
    float brdf = distribution * geometryV * geometryL * waterFresnel(vh) / max(4.0 * nv * nl, 0.001);
    return radiance * brdf * nl;
}

vec3 waterDirectSpecular(vec3 normalView, vec3 viewPosition, float roughness) {
#if SIMPLE_DIMENSION != 0
    return vec3(0.0);
#endif
    vec3 view = safeNormalize(-viewPosition, normalView);
    return waterLightSpecular(normalView, view, normalize(sunPosition), getSunLightColor(), roughness)
         + waterLightSpecular(normalView, view, normalize(moonPosition), getMoonLightColor(), roughness);
}

#endif
