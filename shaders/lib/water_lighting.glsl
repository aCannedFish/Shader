/* 水面局部光照与 GGX 高光；只供片元阶段使用。 */
#ifndef LIB_WATER_LIGHTING_GLSL
#define LIB_WATER_LIGHTING_GLSL

#include "/lib/lighting.glsl"
#include "/lib/space.glsl"
#include "/lib/water.glsl"

// shadowtex1 不含半透明水体，避免水面把自身遮成黑色。
uniform sampler2D shadowtex1;

// Minecraft 光照坐标的端点是 8/256 与 248/256，对应等级 0 与 15。
float waterSkyLevel(float lightmapY) {
    return clamp((lightmapY - 0.03125) / 0.9375, 0.0, 1.0);
}

float waterSkyVisibility(float lightmapY) {
    return smoothstep(0.02, 0.95, waterSkyLevel(lightmapY));
}

// 同时保留阴影距离淡出与入射角偏移，水体仅接收不透明物体投出的阴影。
float waterOpaqueShadow(vec4 shadowClipPos, vec3 normalView, float viewDistance) {
#if ENABLE_SHADOWS == 0
    return 1.0;
#else
    if (shadowClipPos.w <= 0.0) {
        return 1.0;
    }
    vec3 uv = shadowClipToUv(shadowClipPos);
    if (any(lessThan(uv, vec3(0.0))) || any(greaterThan(uv, vec3(1.0)))) {
        return 1.0;
    }
    float incidence = max(dot(normalView, getLightDirView()), 0.0);
    float bias = mix(SHADOW_BIAS * 8.0, SHADOW_BIAS, incidence);
    float sum = 0.0;
    float count = 0.0;
    for (int x = -SHADOW_SOFTNESS; x <= SHADOW_SOFTNESS; x++) {
        for (int y = -SHADOW_SOFTNESS; y <= SHADOW_SOFTNESS; y++) {
            vec2 offset = vec2(float(x), float(y)) / float(shadowMapResolution);
            float blocker = texture2D(shadowtex1, uv.xy + offset).r;
            sum += step(uv.z - bias, blocker);
            count += 1.0;
        }
    }
    float fade = 1.0 - smoothstep(shadowDistance * 0.75, shadowDistance * 0.95, viewDistance);
    return mix(1.0, sum / count, fade);
#endif
}

// 当地光照贴图包含方块光；无天光时不再把它染成随日夜变化的天空颜色。
vec3 waterDiffuse(vec3 albedo, vec3 normalView, vec2 lmCoord,
                  float directVisibility, vec3 viewPosition) {
    vec3 ambient = surfaceAmbientAt(lmCoord, 1.0, normalView, viewPosition);
    float sunCosine = max(dot(normalView, normalize(sunPosition)), 0.0);
    float moonCosine = max(dot(normalView, normalize(moonPosition)), 0.0);
    vec3 direct = getSunLightColor() * sunCosine + getMoonLightColor() * moonCosine;
    return albedo * (ambient + direct * directVisibility);
}

// GGX 分布与 Smith 遮蔽近似，太阳/月亮都使用水的 Fresnel，避免任意白色亮斑。
vec3 waterLightSpecular(vec3 normal, vec3 view, vec3 light, vec3 radiance) {
    vec3 halfVector = safeNormalize(view + light, normal);
    float nv = max(dot(normal, view), 0.001);
    float nl = max(dot(normal, light), 0.0);
    float nh = max(dot(normal, halfVector), 0.0);
    float vh = max(dot(view, halfVector), 0.0);
    float alpha = max(WATER_ROUGHNESS * WATER_ROUGHNESS, 0.006);
    float alphaSquared = alpha * alpha;
    float denominator = nh * nh * (alphaSquared - 1.0) + 1.0;
    float distribution = alphaSquared / (PI * denominator * denominator);
    float k = (WATER_ROUGHNESS + 1.0) * (WATER_ROUGHNESS + 1.0) / 8.0;
    float geometryV = nv / (nv * (1.0 - k) + k);
    float geometryL = nl / (nl * (1.0 - k) + k);
    float brdf = distribution * geometryV * geometryL * waterFresnel(vh) / max(4.0 * nv * nl, 0.001);
    return radiance * brdf * nl;
}

vec3 waterDirectSpecular(vec3 normalView, vec3 viewPosition) {
    vec3 view = safeNormalize(-viewPosition, normalView);
    return waterLightSpecular(normalView, view, normalize(sunPosition), getSunLightColor())
         + waterLightSpecular(normalView, view, normalize(moonPosition), getMoonLightColor());
}

#endif
