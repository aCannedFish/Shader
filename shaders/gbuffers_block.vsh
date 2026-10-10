#version 120

/*
================================================================================
 gbuffers_block.vsh —— 方块实体顶点着色器
================================================================================
 渲染对象：
   * 床、箱子等方块实体的模型表面

 顶点变换与地形相同，区别全在片元着色器里。
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
