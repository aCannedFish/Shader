#version 120

/*
================================================================================
 gbuffers_water.vsh —— 水面（半透明几何体）顶点着色器
================================================================================
 水面是一个"半透明"程序：它在地形之后绘制，并且会和已经画好的像素做
 alpha 混合（所以透过水能看到水底的沙子）。

 这个文件在标准顶点变换之外，多加了一步【顶点动画】：
 把水面顶点的 y 坐标按波浪函数上下移动，水面就有了起伏。
 这是学习"如何在顶点着色器里改几何形状"最直观的例子。

 注意渲染顺序：水面在地形之后绘制，因此它不会出现在后面 composite
 的泛光里 —— 这也是为什么色调映射必须放在最后的 final 程序，
 否则水面和地形就会一个被映射过、一个没有，接缝会很明显。
================================================================================
*/

#include "/lib/vertex_transform.glsl"
#include "/lib/water.glsl"

attribute vec2 mc_Entity;


void main() {
    // 复制一份位置，因为我们要在它上面做位移。
    // gl_Vertex 是只读的顶点属性，先复制再修改。
    vec3 displacedPosition = gl_Vertex.xyz;

#if ENABLE_WATER_WAVES == 1
    // 转成绝对世界坐标再取相位，波浪才不会跟着玩家跑（见 lib/water.glsl 的说明）。
    vec3 playerPos = (gbufferModelViewInverse * gl_ModelViewMatrix * gl_Vertex).xyz;
    vec2 worldXZ = (playerPos + cameraPosition).xz;

    // 只在竖直方向上做位移。水平方向不动，避免水体出现"缝"。
    if (gl_Normal.y > 0.9) {
        displacedPosition.y += getWaterWaveHeight(worldXZ, frameTimeCounter);
    }
#endif

    // 位移完之后，走标准的顶点变换流程。
    // 法线不在顶点阶段修改 —— 逐顶点的法线插值会太平滑，
    // 波浪的细节会糊掉，所以法线留到片元着色器里按像素计算。
    transformGBuffersVertex(
        displacedPosition, gl_Normal,
        (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy,
        (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy,
        gl_Color, mc_Entity
    );
}
