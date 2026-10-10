/*
================================================================================
 lib/noise.glsl —— 噪声与抖动
================================================================================
 两个用途：

 1. 抖动（dithering）
    8 位颜色每通道只有 256 级。天空、雾这类大面积平滑渐变，相邻两级之间
    的边界会被眼睛看成一条条同心圆状的色带（banding），非常难看。
    解决办法：给每个像素加上一点点（小于 1 个色阶）的随机偏移，
    让色带边界被打散成噪点 —— 噪点人眼会自动忽略，色带不会。

 2. 噪波纹理（noisetex）
    OptiFine 会生成一张 noiseTextureResolution × noiseTextureResolution
    的随机纹理并绑定到 noisetex，可以自由采样。做雨滴、粒子、随机化
    等效果时非常有用，这里先用它做抖动，也是给后续扩展留的接口。
================================================================================
*/
#ifndef LIB_NOISE_GLSL
#define LIB_NOISE_GLSL

#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"

// OptiFine 自动生成的随机噪声纹理，三个通道各自独立随机。
#include "sky_noise.glsl"


/* ---------------------------------------------------------------------------
 * 抖动
 *   给屏幕坐标加上 frameCounter，让每一帧的噪声图案都不同。
 *   如果每帧图案相同，静态画面上的噪点会被看成固定的脏点，反而更明显。
 * ------------------------------------------------------------------------ */
vec3 applyDither(vec3 color, vec2 screenCoord) {
#if ENABLE_DITHER == 0
    return color;
#else
    // 1. 把屏幕坐标映射到噪声纹理的范围内。
    //    乘以分辨率和 "每像素多少个噪声纹素" 的比值，这里取 1 像素 1 纹素。
    vec2 noiseCoord = screenCoord * vec2(viewWidth, viewHeight)
                    / float(noiseTextureResolution);

    // 2. 每帧偏移一点，让噪声图案动起来。
    //    取模是为了避免数值随游戏时长无限增大导致浮点精度丢失
    //    （玩久了画面会开始闪烁，就是这个原因）。
    //    ⚠️ GLSL 120 没有整数取模运算符 %（那是 1.30 才加入的），
    //       所以这里用浮点版的 mod()。
    noiseCoord += mod(float(frameCounter), 64.0) * 0.618;   // 0.618 是黄金比，错位最均匀

    // 3. 采样噪声纹理，取一个通道即可。
    float noise = hash12(gl_FragCoord.xy + mod(float(frameCounter), 64.0) * 0.618);

    // 4. 噪声值范围是 [0,1]，先移到 [-0.5, 0.5]，
    //    再缩小到一个色阶以内（1/255），这样偏移不会改变原本的颜色。
    float offset = (noise - 0.5) / 255.0 * DITHER_STRENGTH;

    // 5. 加到颜色上。因为后面会写成 8 位整数，这点偏移刚好能决定
    //    该像素被舍入到上面一级还是下面一级，色带因此被抹平。
    return color + offset;
#endif
}


/* ---------------------------------------------------------------------------
 * 屏幕空间噪声采样（给后续扩展用）
 *   返回同一像素在整个屏幕范围内保持稳定的 [0,1] 随机值。
 *   和 hash12 的区别：这个来自纹理，相邻像素之间是"白噪声"，
 *   而 hash12 是纯数学计算，成本更低但分布略差。
 * ------------------------------------------------------------------------ */
float sampleScreenNoise(vec2 screenCoord) {
    vec2 noiseCoord = screenCoord * vec2(viewWidth, viewHeight)
                    / float(noiseTextureResolution);
    return texture2D(noisetex, noiseCoord).r;
}

#endif  // LIB_NOISE_GLSL
