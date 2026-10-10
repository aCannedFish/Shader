#version 120

/*
================================================================================
 gbuffers_textured_lit.vsh —— 带贴图、且接受阳光直射的几何体
================================================================================
 顶点着色器与 gbuffers_textured 完全相同。
"是否受光照"是片元着色器的差异，因此两个 .vsh 内容一致。
================================================================================
*/

#include "lib/vertex_transform.glsl"

attribute vec2 mc_Entity;

void main() {
    transformGBuffersVertex(
        gl_Vertex.xyz, gl_Normal,
        (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy,
        (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy,
        gl_Color, mc_Entity
    );
}
