
/*
================================================================================
 gbuffers_textured_lit.fsh —— 带贴图、完全参与光照的几何体
================================================================================
 主要用途：需要投/接收阴影的粒子（例如爆炸粒子、烟雾）。
 与 gbuffers_textured 的区别只有一个：调用完整的 computeLighting()，
 因而会受阳光方向、阴影贴图和昼夜变化的影响。
================================================================================
*/

#include "../lib/fragment_output.glsl"
#include "../lib/fog.glsl"


void main() {
    // 1. 材质颜色
    vec4 texel = texture2D(texture, vTexCoord);
    vec4 albedo = vec4(weatherParticleColor(texel.rgb), texel.a) * vColor;
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);
    if (albedo.a < alphaTestRef) {
        discard;
    }

    // 2. 准备光照参数
    vec3 normalView = vNormalView;
    vec2 lmCoord    = prepareLightmapCoord(vLightmapCoord);
    vec3 lmColor    = sampleLightmapColor(lmCoord);
    float viewDistance = length(vViewPos);

    // 3. 完整的阴影 + 光照，和地形的处理完全一致
    vec3 shadow = getShadowFactor(vShadowClipPos, normalView, viewDistance);
    vec3 color = computeLighting(albedo.rgb, normalView, lmColor, lmCoord, shadow, vViewPos);

    // 4. 雾
    color = applyFog(color, viewDistance);

    writeGBuffers(color, normalView, lmCoord, shadow, MAT_SOLID, albedo.a);
}
