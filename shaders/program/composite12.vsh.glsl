#define SIMPLE_VARYING out

in vec3 vaPosition;
in vec4 vaColor;
in vec3 vaNormal;
in vec2 vaUV0;
in ivec2 vaUV2;
uniform vec3 modelOffset;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
uniform mat3 normalMatrix;

/*
================================================================================
 composite3.vsh —— 后处理全屏顶点着色器
================================================================================
 与 composite.vsh 完全相同。OptiFine 要求每个编号的后处理程序
 都有自己的 .vsh，所以这里重复一份；内容相同是因为
 所有后处理程序渲染的都是同一个全屏四边形。
================================================================================
*/

void main() {
    gl_Position = (projectionMatrix * modelViewMatrix * vec4(vaPosition + modelOffset, 1.0));
}

