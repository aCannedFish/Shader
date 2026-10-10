#version 120

/* 天气顶点阶段。使用加载器提供的雨雪几何与统一视图投影，输出透明绘制所需属性。
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
