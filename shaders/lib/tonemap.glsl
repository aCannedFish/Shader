/* HDR 亮度映射与色域约束。保持中间调的色相，控制曝光、饱和度、对比度与显示编码。
 */
#ifndef LIB_TONEMAP_GLSL
#define LIB_TONEMAP_GLSL

#include "../settings.glsl"
#include "common.glsl"


/* ---------------------------------------------------------------------------
 * 方案一：Reinhard
 *   公式：c / (1 + c)
 *   最早也最简单的一条曲线。优点是绝不会超过 1，缺点是整体偏灰、
 *   对比度低，高光缺少"电影感"。
 * ------------------------------------------------------------------------ */
float tonemapReinhard(float color) {
    return color / (1.0 + color);
}


/* ---------------------------------------------------------------------------
 * 方案二：ACES 电影胶片曲线（多项式拟合版）
 *   这是 Narkowicz 在 2016 年给出的拟合公式，被业界广泛使用。
 *   它模拟了胶片对高光的"肩部"压缩：亮度越高压缩越强，
 *   同时暗部还有一点点提亮（"趾部"），因此画面比 Reinhard 耐看得多。
 *
 *   注意：这个公式的输入约定是"曝光后"的线性颜色，
 *   典型输入范围是 [0, ~16]，超过 16 的部分会被强制压到接近 1。
 * ------------------------------------------------------------------------ */
float tonemapACES(float color) {
    // 保留已有的拟合参数，本实现只对亮度分量应用曲线。
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;

    // 分子是二次多项式（控制肩部），分母也是二次（控制趾部）。
    float numerator = color * (a * color + b);
    float denominator = color * (c * color + d) + e;

    // 将拟合曲线的高端输出限制在显示亮度范围内。
    return clamp(numerator / denominator, 0.0, 1.0);
}


// 保留亮度，把超出显示色域的色度向中性轴连续压缩。
// 饱和度与对比度处理后统一执行，负通道与过亮通道都不会被单独硬裁切。
vec3 fitDisplayGamut(vec3 color) {
    float luminance = clamp(luma(color), 0.0, 1.0);
    vec3 chroma = color - vec3(luminance);
    float upper = max(chroma.r, max(chroma.g, chroma.b));
    float lower = min(chroma.r, min(chroma.g, chroma.b));
    float scale = min(1.0, (1.0 - luminance) / max(upper, EPSILON));
    scale = min(scale, luminance / max(-lower, EPSILON));
    return vec3(luminance) + chroma * scale;
}

// 极弱的冷暗暖亮色温分离。中性灰、纯黑和高饱和光源不受染色，
// 颜色变化后恢复原亮度，让天气灰阶与彩色发光保持可预测。
vec3 gradeNaturalColor(vec3 color) {
    float luminance = luma(color);
    float peak = max(color.r, max(color.g, color.b));
    float low = min(color.r, min(color.g, color.b));
    float saturation = (peak - low) / max(peak, EPSILON);
    float amount = smoothstep(0.04, 0.18, saturation)
                 * (1.0 - smoothstep(0.60, 0.90, saturation));
    float shadows = 1.0 - smoothstep(0.04, 0.45, luminance);
    float highlights = smoothstep(0.30, 0.85, luminance);
    vec3 balance = mix(vec3(1.0), vec3(0.97, 1.005, 1.025), shadows * amount * 0.5);
    balance *= mix(vec3(1.0), vec3(1.025, 1.005, 0.975), highlights * amount * 0.5);
    vec3 graded = color * balance;
    return graded * (luminance / max(luma(graded), EPSILON));
}

/* 曝光、亮度曲线和调色使用一个显示出口，全部在线性空间执行。 */
vec3 applyTonemap(vec3 color) {
    // 1. 曝光：在映射之前整体缩放亮度。
    //    这相当于相机的"进光量"，是唯一能在映射前提亮暗部的操作。
    color *= EXPOSURE;

    // 2. 以亮度映射曝光，保持中间调的通道比例。
    // 逐通道强曲线会把绿色进一步增艳，并把暖光推向黄白色。
    color = max(color, vec3(0.0));
    float luminance = luma(color);
#if TONEMAP_MODE == 0
    color = clamp(color, 0.0, 1.0);
#else
#if TONEMAP_MODE == 2
    float mappedLuminance = tonemapReinhard(luminance);
#else
    float mappedLuminance = tonemapACES(luminance);
#endif
    // 小幅抬升中间调；黑点和白点不动，亮部继续由原曲线压缩。
    mappedLuminance += 0.08 * mappedLuminance * (1.0 - mappedLuminance);
    color *= mappedLuminance / max(luminance, EPSILON);
    color = gradeNaturalColor(color);
    // 色域边界处向同亮度中性颜色收敛，软化高光，避免单通道硬裁切。
    float peak = max(color.r, max(color.g, color.b));
    float chromaScale = min(1.0, (1.0 - mappedLuminance)
        / max(peak - mappedLuminance, EPSILON));
    color = mix(vec3(mappedLuminance), color, chromaScale);
#endif

    // 3. 饱和度围绕亮度调整；对比度以中灰为锚点，保留暗部的连续过渡。
    color = applySaturation(color, SATURATION);
    float gradedLuminance = luma(color);
    float contrastedLuminance = 0.18 * pow(max(gradedLuminance / 0.18, EPSILON), CONTRAST);
    color *= contrastedLuminance / max(gradedLuminance, EPSILON);
    return clamp(fitDisplayGamut(color), 0.0, 1.0);
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
