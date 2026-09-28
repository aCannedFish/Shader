#version 120

/*
================================================================================
 gbuffers_clouds.vsh —— 云顶点着色器
================================================================================
 云是普通的方块状几何体（一堆被拉伸的立方体），顶点变换与地形一致。

 想让云飘动？在 transformGBuffersVertex 之前修改 gl_Vertex.xyz 的副本，
 例如：
     vec3 p = gl_Vertex.xyz;
     p.xz += frameTimeCounter * vec2(1.2, 0.4);   // 云层平移
 注意要用绝对世界坐标做相位，理由见 lib/water.glsl 的说明。
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
