
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


void main() {
    vec4 texel = texture2D(texture, vTexCoord);
    vec4 albedo = texel * vColor;
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
    float rain = smoothstep(0.05, 0.20, texel.b - max(texel.r, texel.g));
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
    gl_FragData[0] = vec4(color, albedo.a);
#if DEBUG_VIEW == 0
    // R/G remain the water parameters. B/A are an independent rain layer.
    gl_FragData[1] = rainOverlayMoments(rainIntensity, albedo.a * rain);
#endif
}
