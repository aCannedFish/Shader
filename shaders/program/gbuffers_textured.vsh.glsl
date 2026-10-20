
/*
================================================================================
 gbuffers_textured.vsh —— 带贴图、不受光照影响的几何体
================================================================================
 使用场景：不参与光照的粒子、部分 UI 元素、附魔台的文字等。
 和 gbuffers_basic 唯一的区别就是这类几何体会用到第一套 UV（贴图坐标）。

 注意：顶点着色器与 basic 完全一样 —— "受不受光照"是片元着色器的区别，
 顶点阶段无从得知，也不该知道。
================================================================================
*/

#include "../lib/vertex_transform.glsl"

attribute vec2 mc_Entity;

void main() {
    transformGBuffersVertex(
        gl_Vertex.xyz, gl_Normal,
        (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy,
        (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy,
        gl_Color, mc_Entity
    );
}
