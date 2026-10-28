/*
================================================================================
 lib/fragment_output.glsl —— gbuffers 片元输出（片元着色器专用）
================================================================================
 所有 gbuffers_* 片元着色器最后都要做同一件事：
   把结果写进 3 张颜色缓冲区（MRT，多渲染目标）。

 本项目使用的缓冲区分配（改动这里之前请先想清楚，因为后处理依赖它）：

   colortex0  场景颜色
              rgb = 已经算完光照和雾的 HDR 颜色
              a   = 透明度（给 _a 半透明程序用，其它时候为 1）

   colortex1  几何缓冲区 G-Buffer
              rg = 视图空间法线的八面体编码（完整球面）
              b  = 天空光等级
              a  = 材质标记（MAT_SOLID / MAT_WATER / ...）

   colortex2  光照缓冲区
              r = 方块光等级
              g = 天空光等级
              b = 阴影系数（1 = 受光，0 = 被遮挡）
              a = 材质类别与贴图亮度，由地形阶段补写

 为什么要拆成三张而不是塞进一张？
   1. 后处理需要的信息（法线、深度）和最终颜色是两种数据，
      混在一起就没法在被泛光污染之后还还原出干净的法线；
   2. 各阶段按寿命复用附件；colortex1 使用 16 位浮点，同时承载透明阶段
      的水面参数与雨层光学深度，colortex2 保留透明颜色的 HDR 范围。

 【只应被 .fsh 引用】—— 它写入了 gl_FragData，顶点着色器里不存在。
================================================================================
*/
#ifndef LIB_FRAGMENT_OUTPUT_GLSL
#define LIB_FRAGMENT_OUTPUT_GLSL

#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"
#include "color_space.glsl"
#include "lighting.glsl"
#include "shadow.glsl"          // 需要 getShadowFactor()
#include "varyings.glsl"

// 方块/物品的贴图图集。天气、粒子等程序也会绑定这张图集。
uniform sampler2D texture;

/* ---------------------------------------------------------------------------
 * 实体叠加色
 *   实体受伤会闪红。游戏不通过改变顶点颜色实现，而是提供 entityColor，
 *   它的 a 分量表示叠加强度。
 * ------------------------------------------------------------------------ */
vec4 applyEntityColor(vec4 color) {
    color.rgb = mix(color.rgb, toLinearSpace(entityColor.rgb), entityColor.a);
    return color;
}


/* ---------------------------------------------------------------------------
 * 写出 G-Buffer
 *
 * 参数：
 *   color       已经算完光照（+雾）的线性空间颜色，可以大于 1
 *   normalView  视图空间法线
 *   lightmapCoord 光照贴图坐标（x = 方块光，y = 天空光）
 *   shadow      阴影系数
 *   material    材质标记，用 lib/common.glsl 里的 MAT_* 常量
 *   alpha       输出到 colortex0 的透明度
 * ------------------------------------------------------------------------ */
void writeGBuffers(vec3 color, vec3 normalView, vec2 lightmapCoord,
                   float shadow, float material, float alpha) {
    vec2 lm = prepareLightmapCoord(lightmapCoord);

    // 目标 0：场景颜色。这是后处理真正会去读的那张图。
    gl_FragData[0] = vec4(color, alpha);

    // 目标 1：八面体法线与几何标记；RGBA8 存储保留有限的角度精度。
    gl_FragData[1] = vec4(encodeNormal(normalView), lm.y, material);

    // 目标 2：光照信息。后处理和调试视图都要用。
    gl_FragData[2] = vec4(lm.x, lm.y, shadow, 0.0);
#ifdef WORLD_GPU_BACKEND
    // Attachment 5 holds opaque base radiance until deferred publishes source 4;
    // that pass clears it before its later water-geometry lifetime begins.
    gl_FragData[3] = vec4(color, 1.0);
#else
    // 无材质数据的几何清除后方表面遗留的PBR参数。
    gl_FragData[3] = vec4(0.0);
    // 手部程序不映射该附件，也不生成写入，保证原生场景背景完整保留。
#ifndef FIRST_PERSON_HAND
    gl_FragData[4] = vec4(color, 1.0);
#endif
#endif
}

// 彩色日光传递在缓冲中只保留平均可见度。
void writeGBuffers(vec3 color, vec3 normalView, vec2 lightmapCoord,
                   vec3 shadow, float material, float alpha) {
    writeGBuffers(color, normalView, lightmapCoord, dot(shadow, vec3(1.0 / 3.0)), material, alpha);
}

#endif  // LIB_FRAGMENT_OUTPUT_GLSL
