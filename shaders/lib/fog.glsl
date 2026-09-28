/*
================================================================================
 lib/fog.glsl —— 大气雾 / 水下雾
================================================================================
 为什么需要雾？
   1. 它模拟大气散射：远处的物体因为中间隔着厚厚的空气，对比度下降、
      颜色被天空的颜色"洗掉"。
   2. 它藏住边界：玩家的可视距离是有限的，如果远处物体直接"刷"地消失会
      非常突兀。雾让几何体的尽头自然融入天空。

 本实现不依赖游戏的雾参数，而是自己根据视距（far）算一条曲线，
 这样在游戏里调整渲染距离时表现是一致的、可预期的。
================================================================================
*/
#ifndef LIB_FOG_GLSL
#define LIB_FOG_GLSL

#include "/settings.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/common.glsl"
#include "/lib/color_space.glsl"
#include "/lib/lighting.glsl"

/* 本文件用到的 uniform（全部在 lib/uniforms.glsl 中声明）：
 *   fogColor        游戏提供的地平线雾颜色（vec3）
 *   far             投影远平面距离 = 渲染距离，自定义雾的基准
 *   skyColor        天空颜色，用来给雾染色
 *   isEyeInWater    0 = 空气，1 = 水，2 = 岩浆，3 = 细雪
 */


/* ---------------------------------------------------------------------------
 * 计算给定距离处的雾浓度
 *   返回 0 = 完全清晰，1 = 完全被雾遮蔽
 * ------------------------------------------------------------------------ */
float getFogFactor(float distanceToCamera) {
    if (isEyeInWater == 1) {
        // 水下：能见度极低，而且几乎立刻开始衰减。
        // 用指数雾而不是线性雾，因为水里颗粒物造成的散射更接近指数衰减。
        float waterDensity = 0.06 * FOG_DENSITY;
        // 1 - e^(-density * distance)：距离越远，结果越接近 1
        return 1.0 - exp(-waterDensity * distanceToCamera);
    }

    // 空气中：线性雾。
    // 起点定在 55% 视距 —— 太近会让世界灰蒙蒙的，太远又藏不住边界。
    // FOG_DENSITY 越大，分母越大，雾开始得越早。
    float fogStart = far * 0.55 / max(FOG_DENSITY, EPSILON);
    float fogEnd   = far * 0.98 / max(FOG_DENSITY, EPSILON);

    // smoothstep 比 linear 好在两端导数为 0：
    // 雾的"出现"和"饱和"都是渐进的，不会有可见的硬边。
    return smoothstep(fogStart, fogEnd, distanceToCamera);
}


/* ---------------------------------------------------------------------------
 * 计算雾的颜色。
 *   fogColor 是游戏提供的地平线颜色，随日夜、天气及视线方向变化。
 *   远处地形直接趋向这个颜色，才能与天空边缘接上。
 * ------------------------------------------------------------------------ */
vec3 getFogColor() {
    if (isEyeInWater == 1) {
        // 水下：偏青蓝，并且明显压暗，模拟光线被吸收。
        return vec3(0.08, 0.22, 0.35);
    }
    if (isEyeInWater == 2) {
        return vec3(0.60, 0.15, 0.02);  // 岩浆
    }

    // 游戏的 fogColor 就是地平线颜色，并且已随时间、天气更新。
    // 与天空使用同一输入和转换，避免远处地形出现另一种颜色的色带。
    return toLinearSpace(fogColor.rgb);
}


/* ---------------------------------------------------------------------------
 * 对外的总入口：对颜色应用雾
 *
 * 参数：
 *   color              已经算完光照的颜色
 *   distanceToCamera   该点到摄像机的直线距离（单位：方块）
 *
 * 返回：混合了雾之后的颜色。
 * ------------------------------------------------------------------------ */
vec3 applyFog(vec3 color, float distanceToCamera) {
    float fogFactor = getFogFactor(distanceToCamera);

    // mix(a, b, t) = a * (1-t) + b * t
    // fogFactor 接近 1 时颜色几乎完全变成雾色。
    return mix(color, getFogColor(), fogFactor);
}

#endif  // LIB_FOG_GLSL
