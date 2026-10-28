/* 水面细节法线与像素足迹过滤。几何位移保留 water.glsl 中的长波，细节只改变法线。
 *
 * 为什么不用正弦叠加：有限个正弦之和是周期函数，远看会出现规则条纹，
 * 几组方向不同的正弦交叉后还会形成网格。这里改为四层随机值噪声：
 *   - 每层各自旋转到接近风向的不同角度，避免共用同一套网格轴；
 *   - 沿传播方向较密、沿波峰方向拉长，形成长短不一的波峰，而不是圆斑；
 *   - 波长按约 2 倍递减、振幅更快递减，细碎波纹只做点缀，整体密度较低；
 *   - 各层按深水色散的趋势移动：长波较快、短波较慢，时间上不会整体平移。
 * 噪声导数是解析求得的，每层只需四次哈希，不需要额外的有限差分采样。
 * 无法被当前像素分辨的层逐渐退出，避免远处波纹与高光闪烁。
 */
#ifndef LIB_WATER_SURFACE_GLSL
#define LIB_WATER_SURFACE_GLSL
#include "water.glsl"
#include "weather.glsl"
#include "wave_noise.glsl"


vec3 waterSurfaceNormal(vec2 position, float time, float footprint) {
    float t = time * WAVE_SPEED;
    // 四层的传播方向都在主风向 ±60° 内，比完全随机的方向更像风吹出的水面。
    vec2 slope = waterWaveOctave(position, t, 0.35, 9.0, 2.0, 0.85, 0.24,
                                 vec2(0.0), footprint);
    slope += waterWaveOctave(position, t, -0.28, 4.4, 1.8, 0.60, 0.095,
                             vec2(17.3, -41.9), footprint);
    // 细波受雨滴扰动更强，雨天会更碎一些，但仍低于旧版的密集波纹。
    float rain = mix(1.0, 1.45, weatherRainAmount());
    slope += waterWaveOctave(position, t, 0.98, 2.15, 1.6, 0.42, 0.033 * rain,
                             vec2(-63.1, 27.7), footprint);
    slope += waterWaveOctave(position, t, -0.75, 1.1, 1.4, 0.30, 0.0115 * rain,
                             vec2(91.4, 55.2), footprint);
    // 上下视角共用可辨认的波峰斜率，折射窗口与倒影随同一水面连续起伏。
    return normalize(vec3(-slope.x * 2.2, 1.0, -slope.y * 2.2));
}

#endif
