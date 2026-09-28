#version 120

/*
================================================================================
 gbuffers_hand.fsh —— 第一人称手持物品片元着色器
================================================================================
 光照与地形完全一致。这里演示一个常见的"程序级微调"技巧：
 用 shaders.properties / settings.glsl 之外的方式，让手持物品的雾更淡。

 手持物品到摄像机的距离只有 0.5~1.5 个方块，正常雾参数下几乎不受影响；
 但水下和雨天的雾浓度很高时，手臂会被染成一片蓝色，视觉上很怪。
 因此这里给雾的距离乘一个"虚化系数"，让它对应到更远的距离上。
================================================================================
*/

#include "/lib/fragment_output.glsl"
#include "/lib/fog.glsl"


void main() {
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);
    if (albedo.a < alphaTestRef) {
        discard;
    }

    vec3 normalView = vNormalView;
    vec2 lmCoord    = prepareLightmapCoord(vLightmapCoord);
    vec3 lmColor    = sampleLightmapColor(lmCoord);
    float viewDistance = length(vViewPos);

    // 手持物品不受阴影影响：它离摄像机太近，阴影贴图在这个尺度上没有精度，
    // 硬算反而会出现一块块的黑斑。所以阴影系数直接给 1。
    float shadow = 1.0;

    vec3 color = computeLighting(albedo.rgb, normalView, lmColor, lmCoord, shadow);

    // 雾的"等效距离"放大 4 倍，等价于把手持物品放进更淡的雾里。
    // 想让手臂完全不受雾影响，把 4.0 改成 1000.0 即可。
    color = applyFog(color, viewDistance * 4.0);

    writeGBuffers(color, normalView, lmCoord, shadow, MAT_SOLID, albedo.a);
}
