/*
================================================================================
 lib/water.glsl —— 水面波浪
================================================================================
 一个"可自由开关的扩展示例"，用来演示两件事：
   1. 怎么在顶点着色器里做顶点动画（改变几何形状）；
   2. 怎么让顶点和片元共享同一份函数，保证位移与法线完全一致。

 原理：用几个不同频率、不同方向、不同速度的正弦波叠加。
   单个正弦波看起来像"整齐的水泥波浪"，叠加 3 个之后相位互相错开，
   就会显得不规则、像真的水面。这就是最朴素的"正弦波叠加"水。

 ------------------------------------------------------------------------------
 重要概念：为什么相位要用【绝对世界坐标】？
 ------------------------------------------------------------------------------
   gl_Vertex 是模型空间坐标。地形由区块存放，直接使用它会让
   相邻区块的波形重复，移动摄像机时也无法保持相位稳定。
   先经 gl_ModelViewMatrix 和 gbufferModelViewInverse 转到摄像机相对
   的世界坐标，再加 cameraPosition，才能得到绝对世界坐标。
   这样波浪会固定在世界的某个位置。
================================================================================
*/
#ifndef LIB_WATER_GLSL
#define LIB_WATER_GLSL

#include "/settings.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/common.glsl"


// 波浪参数。想让水面更平静就调小这些数。
#define WAVE_AMPLITUDE 0.055   // 波高（方块）
#define WAVE_SPEED     1.35    // 时间缩放，越大波动越快
#define WAVE_SCALE     0.85    // 空间频率，越大波浪越密


/*
 * 计算某个世界坐标处的水面高度偏移。
 *   worldXZ  绝对世界坐标的 xz 分量
 *   time     累计时间（秒），直接传 frameTimeCounter
 */
float getWaterWaveHeight(vec2 worldXZ, float time) {
    float height = 0.0;
    float t = time * WAVE_SPEED;

    // 三个方向不同的波，频率和相位都错开，避免出现规则的"搓衣板"图案。
    height += sin(dot(worldXZ, vec2(0.9, 0.4)) * WAVE_SCALE + t * 1.7) * 0.50;
    height += sin(dot(worldXZ, vec2(-0.6, 1.0)) * WAVE_SCALE * 1.3 - t * 1.1) * 0.35;
    height += sin(dot(worldXZ, vec2(0.3, -1.0)) * WAVE_SCALE * 2.1 + t * 2.3) * 0.15;

    // 三个波按 0.5 / 0.35 / 0.15 的权重叠加，总权重为 1，
    // 所以 height 的范围是 [-1, 1]，乘上振幅就得到实际位移。
    return height * WAVE_AMPLITUDE;
}


/*
 * 计算水面在某个世界坐标处的世界空间法线。
 *
 * 做法：有限差分。
 *   水面高度场 h(x,z) 是一个曲面，曲面上某点的法线可以这样近似：
 *     在 x 方向偏移很小的 eps，分别求出两侧高度，得到切向量的 xz 斜率；
 *     在 z 方向同理。
 *   法线 = normalize(vec3(-dh/dx, 1, -dh/dz))
 *
 *   eps 取 0.25 个方块：太小会让波浪显得过于尖锐（而且可能采到同一个顶点
 *   导致全零向量），太大又会让相邻顶点的法线差异被抹平。
 */
vec3 getWaterWaveNormal(vec2 worldXZ, float time) {
    const float eps = 0.25;

    float hL = getWaterWaveHeight(worldXZ - vec2(eps, 0.0), time);
    float hR = getWaterWaveHeight(worldXZ + vec2(eps, 0.0), time);
    float hD = getWaterWaveHeight(worldXZ - vec2(0.0, eps), time);
    float hU = getWaterWaveHeight(worldXZ + vec2(0.0, eps), time);

    float dHdx = (hR - hL) / (2.0 * eps);
    float dHdz = (hU - hD) / (2.0 * eps);

    // 世界空间的 y 轴朝上，所以基础法线是 (0,1,0)。
    // 斜率越大，法线越偏离竖直方向。（取负号是链式法则的结果）
    return normalize(vec3(-dHdx, 1.0, -dHdz));
}

#endif  // LIB_WATER_GLSL
