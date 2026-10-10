/* HDR 色调映射与颜色调整。提供 ACES/Reinhard 曲线、曝光、饱和度、对比度和显示编码。
 */
#ifndef LIB_TONEMAP_GLSL
#define LIB_TONEMAP_GLSL

#include "/settings.glsl"
#include "/lib/common.glsl"


/* ---------------------------------------------------------------------------
 * 方案一：Reinhard
 *   公式：c / (1 + c)
 *   最早也最简单的一条曲线。优点是绝不会超过 1，缺点是整体偏灰、
 *   对比度低，高光缺少"电影感"。
 * ------------------------------------------------------------------------ */
vec3 tonemapReinhard(vec3 color) {
    return color / (1.0 + color);
}


/* ---------------------------------------------------------------------------
 * 方案二：ACES 电影胶片曲线（多项式拟合版）
 *   这是 Narkowicz 在 2015 年给出的拟合公式，被业界广泛使用。
 *   它模拟了胶片对高光的"肩部"压缩：亮度越高压缩越强，
 *   同时暗部还有一点点提亮（"趾部"），因此画面比 Reinhard 耐看得多。
 *
 *   注意：这个公式的输入约定是"曝光后"的线性颜色，
 *   典型输入范围是 [0, ~16]，超过 16 的部分会被强制压到接近 1。
 * ------------------------------------------------------------------------ */
vec3 tonemapACES(vec3 color) {
    // 拟合曲线使用的两个系数，来自论文中的最小二乘拟合结果。
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;

    // 分子是二次多项式（控制肩部），分母也是二次（控制趾部）。
    vec3 numerator   = color * (a * color + b);
    vec3 denominator = color * (c * color + d) + e;

    // 结果已经保证落在 [0,1] 内，clamp 只是为了防御 NaN。
    return clamp(numerator / denominator, 0.0, 1.0);
}


/* ---------------------------------------------------------------------------
 * 对外的总入口：按设置选择曲线
 * ------------------------------------------------------------------------ */
vec3 applyTonemap(vec3 color) {
    // 1. 曝光：在映射之前整体缩放亮度。
    //    这相当于相机的"进光量"，是唯一能在映射前提亮暗部的操作。
    color *= EXPOSURE;

    // 2. 曲线本身
#if TONEMAP_MODE == 0
    // 关闭：直接截断。可以用来观察 HDR 数据的原始状态。
    color = clamp(color, 0.0, 1.0);
#elif TONEMAP_MODE == 2
    color = tonemapReinhard(color);
#else
    color = tonemapACES(color);
#endif

    // 3. 调色：饱和度与对比度。
    //    放在色调映射【之后】是有意的 —— 映射会把高光压扁，
    //    之后再调色才能让调色结果稳定、可预测。
    color = applySaturation(color, SATURATION);
    color = applyContrast(color, CONTRAST);

    return color;
}


/* ---------------------------------------------------------------------------
 * 线性空间 -> 显示空间（sRGB 传输函数）
 *
 * 整条管线（光照、泛光、混合）都在"线性空间"里计算，物理上才对。
 * 但显示器期望的是 sRGB 编码的值，所以最后一步必须把线性值转回去。
 * ------------------------------------------------------------------------ */
vec3 toDisplaySpace(vec3 color) {
    // 严格的 sRGB 传输函数是分段的，这里用 gamma 2.2 近似，
    // 误差在 1% 以内，视觉上完全看不出来，且只有一次 pow，开销更低。
    return pow(max(color, 0.0), vec3(1.0 / 2.2));
}

#endif  // LIB_TONEMAP_GLSL
