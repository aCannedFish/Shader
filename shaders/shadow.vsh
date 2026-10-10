#version 120

/*
================================================================================
 shadow.vsh —— 阴影贴图顶点着色器
================================================================================
 这个程序【不渲染任何颜色】，它只做一件事：
 站在太阳的位置，把整个世界的深度信息烤进一张贴图。

 渲染过程：
   1. OptiFine 把场景里所有会投影的几何体重新送一遍进来；
   2. gl_ModelViewMatrix 把当前区块/实体从模型空间转到阴影视图空间，
      gl_ProjectionMatrix 再投影；
   3. 施加和 gbuffers 完全一样的畸变；
   4. GPU 自动把深度写进 shadowMap。

 和 gbuffers_terrain.vsh 对照着看会发现：公式一模一样，
 只是把 gbufferModelView/gbufferProjection 换成了 shadow 系列。
 这正是"阴影贴图 = 从光源视角再渲染一遍"的字面含义。

 注意这里【没有】gbufferModelViewInverse：阴影绘制时的内置矩阵
 已经包含了当前几何体的变换，无须重新还原玩家视图空间坐标。

 调试技巧：把 settings.glsl 里 shadowDistance 调小到 32，
 就能在游戏里看清阴影贴图的覆盖范围 —— 超出范围的地方没有阴影。
================================================================================
*/

#include "/settings.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/common.glsl"
#include "/lib/space.glsl"
#include "/lib/foliage_wind.glsl"


// 植被只对已映射的方块生效，实体和普通方块保留原来的位置。
attribute vec2 mc_Entity;
attribute vec3 at_midBlock;

varying vec2 vTexCoord;
varying vec4 vColor;

void main() {
    // 1. 世界空间 -> 太阳的裁剪空间
    vec3 position = gl_Vertex.xyz;
    if (hasFoliageWind(mc_Entity.x)) {
        vec3 shadowViewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
        vec3 worldPosition = (shadowModelViewInverse * vec4(shadowViewPosition, 1.0)).xyz
                           + cameraPosition;
        vec3 blockCenter = worldPosition + at_midBlock / 64.0;
        vec3 root = foliageRoot(blockCenter, mc_Entity.x);
        position += foliageWindOffset(worldPosition, root, mc_Entity.x);
    }
    vec4 shadowClipPos = gl_ProjectionMatrix * gl_ModelViewMatrix * vec4(position, 1.0);

    // 2. 畸变。必须和 gbuffers 用的完全一致，否则采样位置会对不上。
    shadowClipPos.xyz = distortShadow(shadowClipPos.xyz);

    // 3. 交给 GPU 光栅化并写深度
    gl_Position = shadowClipPos;

    // 4. 透传贴图坐标与顶点颜色，供片元着色器做 alpha 测试
    vTexCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vColor = gl_Color;
    if (vColor.a < 0.1) {
        vColor.a = 1.0;
    }
}
