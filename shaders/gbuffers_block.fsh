#version 120

/*
================================================================================
 gbuffers_block.fsh —— 方块选中框 / 挖掘裂纹片元着色器
================================================================================
 这类几何体是"叠加"在方块之上的：描边本身只有一根细线，其余部分完全透明；
 裂纹贴图也是大部分透明、只有纹路不透明。

 所以处理方式和地形恰好相反：
   * 只输出材质本身，【不】做光照、不做雾 ——
     描边应该是纯粹的黑色，被光照照亮就没意义了；
   * 保留 alpha，交给混合状态叠加到已有画面上。
================================================================================
*/

#include "/lib/fragment_output.glsl"


void main() {
    // 描边的颜色来自顶点色（黑），裂纹来自贴图。
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);

    // 透明部分直接丢弃：既省着色开销，也避免它们污染深度缓冲。
    // 描边的线宽只有 1 像素左右，绝大多数像素都会在这里被丢掉。
    if (albedo.a < alphaTestRef) {
        discard;
    }

    // 写出。光照贴图坐标照常传，方便调试视图；颜色不做任何光照处理。
    vec2 lmCoord = prepareLightmapCoord(vLightmapCoord);
    writeGBuffers(albedo.rgb, vNormalView, lmCoord, 1.0, MAT_SOLID, albedo.a);
}
