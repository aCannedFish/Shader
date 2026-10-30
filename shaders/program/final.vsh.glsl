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
 final.vsh —— 最终输出全屏顶点着色器
================================================================================
 final 是整条管线的最后一步，它的输出直接进入屏幕，
 所以这个程序里写的颜色就是玩家最终看到的东西。
 屏幕与内部渲染尺寸可以不同，传递全屏四边形的归一化 UV，
 避免使用内部尺寸去归一化屏幕像素坐标。
================================================================================
*/

SIMPLE_VARYING vec2 vScreenUv;

void main() {
    gl_Position = (projectionMatrix * modelViewMatrix * vec4(vaPosition + modelOffset, 1.0));
    vScreenUv = vec4(vaUV0, 0.0, 1.0).xy;
}

