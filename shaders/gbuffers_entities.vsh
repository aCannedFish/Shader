#version 120

/*
================================================================================
 gbuffers_entities.vsh —— 实体顶点着色器
================================================================================
 渲染对象：生物、掉落物、矿车、船、盔甲架……
 顶点阶段和地形完全一样 —— 实体也是普通的带贴图几何体。
唯一需要注意的是实体的"骨架动画"（僵尸走路、玩家挥手）已经在
    MC 内部算完了，送进来的是动画之后的位置，我们不需要也不应该再去改。
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
