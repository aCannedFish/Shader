#version 120

/*
================================================================================
 gbuffers_weather.vsh —— 雨/雪顶点着色器
================================================================================
 雨雪是一堆垂直的细长四边形，MC 每帧更新它们的位置。
 顶点变换与地形一致。

 想让它斜着下？在变换前给位置加一点水平偏移即可：
     vec3 p = gl_Vertex.xyz;
     p.xz += vec2(1.0, 0.0) * p.y * 0.3;
 这样越高的雨滴偏移越多，整片雨就斜了。
================================================================================
*/

#include "/lib/vertex_transform.glsl"

attribute vec2 mc_Entity;

void main() {
    transformGBuffersVertex(
        gl_Vertex.xyz, gl_Normal,
        (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy,
        (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy,
        gl_Color, mc_Entity
    );
}
