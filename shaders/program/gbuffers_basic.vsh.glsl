
/*
================================================================================
 gbuffers_basic.vsh —— 最基础的几何体顶点着色器
================================================================================
 什么时候会用到这个程序？
   - 生物拴绳、区块边界框、某些调试线框等"只有位置和颜色、没有贴图"的几何体
   - 也是所有其它 gbuffers 程序的兜底：如果某个程序类型没有对应的文件，
     OptiFine 会退回使用 gbuffers_basic

 由于它是最简的，代码几乎就是把顶点变换 + 透传属性走一遍。
 把它当作所有 gbuffers 程序的模板来读最合适：
 结构是「读取顶点属性 -> 变换 -> 写入 varying」。
================================================================================
*/

// 引入公共顶点变换。它内部会包含 settings / uniforms / space / varyings。
#include "../lib/vertex_transform.glsl"


/* ---------------------------------------------------------------------------
 * 顶点属性
 *   GLSL 120 兼容配置使用 gl_* 内置属性。mc_Entity 是额外属性。
 * ------------------------------------------------------------------------ */

// gl_Vertex 是模型空间位置；地形属于区块，实体属于模型。
// gl_MultiTexCoord0 是图集坐标，gl_MultiTexCoord1 是光照贴图坐标。
// 两套坐标都先经过对应的 gl_TextureMatrix 再交给片元着色器。

// 方块或实体的 ID。x = ID，y = 渲染类型。
// basic 程序里基本用不到，但声明出来可以原样传给片元着色器备用。
attribute vec2 mc_Entity;


void main() {
    // 一行搞定：变换坐标 + 填充所有 varying。
    // 具体每一步在 lib/vertex_transform.glsl 里有逐行注释。
    transformGBuffersVertex(
        gl_Vertex.xyz, gl_Normal,
        (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy,
        (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy,
        gl_Color, mc_Entity
    );
}
