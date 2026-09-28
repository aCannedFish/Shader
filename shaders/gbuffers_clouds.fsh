#version 120

/*
================================================================================
 gbuffers_clouds.fsh —— 云片元着色器
================================================================================
 当前版本的原版云网格提供顶点颜色和法线，不提供地形图集坐标。
 因此颜色直接取顶点色，保留 alpha 供混合状态处理。

 光照用的是完整模型 —— 云的顶面朝向天空，会被太阳照亮；
 底面朝下，自然就暗下来了。这是免费得到的一个不错的立体感。
================================================================================
*/

#include "/lib/fragment_output.glsl"
#include "/lib/fog.glsl"


void main() {
    vec4 albedo = vColor;
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);

    // 完全透明的云片元不写深度，其余透明度由混合状态处理。
    if (albedo.a < alphaTestRef) {
        discard;
    }

    vec3 normalView = vNormalView;
    // 云网格没有光照贴图坐标，使用天空颜色作为环境光。
    vec2 lmCoord    = vec2(0.0, 1.0);
    vec3 lmColor    = toLinearSpace(skyColor);
    float viewDistance = length(vViewPos);

    // 云不接收阴影：它离地面很远，阴影贴图根本覆盖不到，
    // 强行采样只会得到噪点。
    float shadow = 1.0;

    vec3 color = computeLighting(albedo.rgb, normalView, lmColor, lmCoord, shadow);

    // 云很白，加一点点自发光让它更像"被阳光穿透的云"。
    color += albedo.rgb * getDayFactor() * 0.15;

    // 云的雾要比地形更淡一些，不然远处的云会糊成一片灰。
    color = applyFog(color, viewDistance * 0.6);

    writeGBuffers(color, normalView, lmCoord, shadow, MAT_SOLID, albedo.a);
}
