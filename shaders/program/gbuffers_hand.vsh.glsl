
/*
================================================================================
 gbuffers_hand.vsh —— 第一人称手持物品顶点着色器
================================================================================
 渲染对象：主手/副手的物品、空手时的玩家手臂。
 顶点变换与地形一致；但这个程序有两个额外可玩点（见片元着色器）：
   * 手持物品通常离眼睛很近，过强的雾会让它看起来"蒙了一层灰"，
     所以一般会减弱甚至关闭它的雾。
   * 部分光影会在这里做"手持物品轻微摇晃"的动画。
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
