#version 120

/*
================================================================================
 gbuffers_skybasic.vsh —— 原版天空（渐变穹顶）顶点着色器
================================================================================
 这是唯一一个不共用 lib/vertex_transform.glsl 的 gbuffers 程序，原因是：

   1. 天空穹顶的顶点坐标是"反投影"出来的（永远贴在远平面上），
      MC 直接给出了最终位置，用固定管线的组合矩阵变换即可。
   2. 天空不需要阴影坐标 —— 它是无穷远的，算阴影毫无意义，
      而且它在屏幕上占据大片区域，省下这几步能实打实提升帧率。

 这里用 gl_ModelViewProjectionMatrix（固定管线内置的"投影 × 模型视图"矩阵），
 它等于 gbufferProjection * gbufferModelView，效果等价但少一次矩阵乘法。
================================================================================
*/

#include "/settings.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/common.glsl"
#include "/lib/varyings.glsl"


void main() {
    // 天空穹顶直接投影到屏幕。
    // 天空没有"阴影"概念，所以 vShadowClipPos 留空（写 0），
    // 片元着色器也不会去读它。
    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;

    // 原版天空的颜色是"逐顶点渐变"的：天顶一种颜色、地平线一种颜色，
    // 中间靠插值过渡。顶点颜色由 gl_Color 提供。
    vColor = gl_Color;

    // 天空不参与光照，但为了其它 varying 有确定值，还是写上安全的默认值。
    vNormalView    = vec3(0.0, 0.0, 1.0);
    vViewPos       = vec3(0.0, 0.0, -1.0);
    vShadowClipPos = vec4(0.0);
    vTexCoord      = vec2(0.0);
    vLightmapCoord = vec2(1.0);      // 天空视作"全亮"
    vEntityId      = vec2(0.0);
}
