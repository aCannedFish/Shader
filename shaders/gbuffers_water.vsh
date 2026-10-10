#version 120

/* 水体顶点阶段。仅对水面顶面施加世界坐标波浪位移，保留边界与非水材质。
 * 片元阶段使用同一高度场计算波浪法线。
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
    if (abs(mc_Entity.x - WATER_BLOCK_ID) < 0.5 && gl_Normal.y > 0.9) {
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
