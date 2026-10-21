
/* 天气顶点阶段。使用加载器提供的雨雪几何与统一视图投影，输出透明绘制所需属性。
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
    // 天气顶点 alpha 包含雨幕的边缘淡出，不能沿用地形的零 alpha 修复。
    vColor = gl_Color;
}
