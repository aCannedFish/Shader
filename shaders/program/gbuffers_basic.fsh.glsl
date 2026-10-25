#ifdef WORLD_GPU_BACKEND
/* RENDERTARGETS: 0,1,2,5 */
#else
/* RENDERTARGETS: 0,1,2 */
#endif

/*
================================================================================
 gbuffers_basic.fsh —— 最基础的几何体片元着色器
================================================================================
 片元着色器为每个被三角形覆盖的像素执行一次，决定这个像素最终是什么颜色。

 一个 gbuffers 片元着色器永远遵循同样的四步：
   1. 取材质颜色（贴图 × 顶点颜色）
   2. 需要的话做 alpha 测试（透明像素直接丢弃）
   3. 计算光照（阴影 + 光照贴图 + 直射光）
   4. 应用雾，写出 G-Buffer

 具体每一步的含义见下方注释；实现细节在 lib/ 里。
================================================================================
*/

// 引入片元输出工具：光照贴图采样、实体叠加色、写出 G-Buffer。
// 它内部会包含 settings / uniforms / lighting / shadow / varyings。
#include "../lib/fragment_output.glsl"

// 雾：按距离把颜色混合向雾色
#include "../lib/fog.glsl"


void main() {
    /* -----------------------------------------------------------------------
     * 第一步：取材质颜色
     * basic 程序渲染的几何体没有贴图，颜色全部来自顶点颜色。
     * -------------------------------------------------------------------- */
    vec4 albedo = vColor;
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);

    /* -----------------------------------------------------------------------
     * 第二步：alpha 测试
     * 完全透明的像素必须被丢弃，否则会占用深度缓冲、挡住后面的东西。
     * alphaTestRef 由游戏提供（对应设置里的"树叶透明"等选项）。
     * 注意 discard 会让 GPU 无法使用早期深度测试，能用 alpha 混合就别 discard，
     * 但透明几何体必须走这一步。
     * -------------------------------------------------------------------- */
    if (albedo.a < alphaTestRef) {
        discard;
    }

    /* -----------------------------------------------------------------------
     * 第三步：光照
     * -------------------------------------------------------------------- */
    vec3 normalView = vNormalView;                       // 视图空间法线
    vec2 lmCoord    = prepareLightmapCoord(vLightmapCoord); // 光照贴图坐标
    vec3 lmColor    = sampleLightmapColor(lmCoord);      // 光照贴图颜色

    // 到摄像机的距离。视图空间里摄像机在原点，所以直接取向量长度。
    // 用它来做雾，以及阴影的距离淡出。
    float viewDistance = length(vViewPos);

    // 阴影系数：1 = 受光，0 = 被遮挡
    vec3 shadow = getShadowFactor(vShadowClipPos, normalView, viewDistance);

    // 环境光 + 直射光
    vec3 color = computeLighting(albedo.rgb, normalView, lmColor, lmCoord, shadow, vViewPos);

    /* -----------------------------------------------------------------------
     * 第四步：雾 + 写出
     * -------------------------------------------------------------------- */
    color = applySurfaceFog(color, viewDistance);

    // 写入 colortex0（颜色）、colortex1（法线等）、colortex2（光照）
    writeGBuffers(color, normalView, lmCoord, shadow, MAT_SOLID, albedo.a);
}
