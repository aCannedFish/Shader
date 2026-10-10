#version 120

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

#include "/lib/fragment_output.glsl"
#include "/lib/fog.glsl"


void main() {
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);

    // 雨的条纹贴图里绝大部分是透明的，这一步会丢弃绝大多数像素。
    // 先做 alpha 测试再做光照，能省下大量无用的光照计算。
    if (albedo.a < alphaTestRef) {
        discard;
    }

    vec3 normalView = vNormalView;
    vec2 lmCoord    = prepareLightmapCoord(vLightmapCoord);
    vec3 lmColor    = sampleLightmapColor(lmCoord);
    float viewDistance = length(vViewPos);

    float shadow = 1.0;   // 雨滴不接收阴影

    vec3 color = computeLighting(albedo.rgb, normalView, lmColor, lmCoord, shadow, vViewPos);

    // 阴雨天整体压暗一点。rainStrength 在 0~1 之间平滑变化，
    // 所以雨停之后会自然恢复，不会有突变。
    color *= 1.0 - rainStrength * 0.35;

    color = applyFog(color, viewDistance);

    writeGBuffers(color, normalView, lmCoord, shadow, MAT_SOLID, albedo.a);
}
