
/*
================================================================================
 gbuffers_weather.fsh —— 雨/雪片元着色器
================================================================================
 雨雪的贴图是半透明的细条纹，靠 alpha 混合叠加到场景上。

 一个常见需求：下雨时整体环境变暗。这里没有在光照里改，
 而是直接在颜色上乘一个系数 —— 因为雨是"覆盖层"，
 它不应该影响场景本身的光照（场景的变暗由天气系统在别处处理）。
================================================================================
*/

#include "../lib/fragment_output.glsl"
#if DEBUG_VIEW == 0
/* RENDERTARGETS: 0,1 */
#else
/* RENDERTARGETS: 0 */
#endif
#include "../lib/fog.glsl"
#include "../lib/rain_ripples.glsl"


void main() {
    vec4 texel = texture2D(texture, vTexCoord);
    vec4 albedo = texel * vColor;
    // 保留原生雨雪网格的遮挡和范围。雨幕改用窄条与落下的短滴，雪花保留贴图。
    // 原生雨图为长条图，雪图为方图；透明纹素不能用于逐片元的雨雪分类。
    float rain = smoothstep(0.05, 0.20, texel.b - max(texel.r, texel.g));
#if __VERSION__ >= 130
    ivec2 weatherSize = textureSize(texture, 0);
    rain = max(rain, step(float(weatherSize.x) * 2.0, float(weatherSize.y)));
#endif
#if ENABLE_REALISTIC_RAIN == 1
    vec3 world = viewToAbsoluteWorld(vViewPos);
    float lane = vTexCoord.x * 3.0;
    vec3 seed = rainImpactHash(floor(world.xz) + floor(lane) * vec2(7.3, 17.1));
    float lateral = abs(fract(lane) - mix(0.2, 0.8, seed.x));
    float width = mix(0.024, 0.045, seed.z);
    float antialias = max(fwidth(lane), 0.003);
    float streak = 1.0 - smoothstep(width - antialias, width + antialias, lateral);
    float fall = fract(world.y * 0.65 + frameTimeCounter * 9.0 + seed.y * 5.0);
    streak *= smoothstep(0.0, 0.04, fall) * (1.0 - smoothstep(0.16, 0.32, fall));
    float rainAlpha = streak * vColor.a * mix(0.38, 0.62, seed.z);
    albedo.a = mix(albedo.a, rainAlpha, rain);
#endif
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);

    // 雨的条纹贴图里绝大部分是透明的，这一步会丢弃绝大多数像素。
    // 先做 alpha 测试再做光照，能省下大量无用的光照计算。
    if (albedo.a <= 0.001 || albedo.a < alphaTestRef) {
        discard;
    }

    vec3 normalView = vNormalView;
    vec2 lmCoord    = prepareLightmapCoord(vLightmapCoord);
    vec3 lmColor    = sampleLightmapColor(lmCoord);
    float viewDistance = length(vViewPos);

    float shadow = 1.0;   // 雨滴不接收阴影

    // 原版雨图偏蓝、雪图接近中性白，用贴图色差保留雪花自身颜色。
    vec3 illumination = surfaceAmbient(lmCoord, 1.0)
                      + (getSunLightColor() + getMoonLightColor()) * 0.12;
    float rainIntensity = luma(illumination) * mix(0.6, 1.2, luma(texel.rgb));
    vec3 color = toLinearSpace(rainDropAlbedo()) * rainIntensity;
    if (rain < 0.999) {
        vec3 snow = computeLighting(albedo.rgb, normalView, lmColor, lmCoord, shadow, vViewPos);
        color = mix(applyFog(snow, viewDistance), color, rain);
    }
    // 远处雨丝随雾消隐，避免被雾色重新染成明亮的蓝白条纹。
    albedo.a *= mix(1.0, 0.45 * (1.0 - getFogFactor(viewDistance)), rain);
    // 雨层在云、雾和水体之后统一合成，避免被远处云层再次覆盖。
#if DEBUG_VIEW == 0
    gl_FragData[0] = vec4(color, albedo.a * (1.0 - rain));
#else
    gl_FragData[0] = vec4(color, albedo.a);
#endif
#if DEBUG_VIEW == 0
    // R/G remain the water parameters. B/A are an independent rain layer.
    gl_FragData[1] = rainOverlayMoments(rainIntensity, albedo.a * rain);
#endif
}
