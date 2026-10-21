/*
================================================================================
 lib/common.glsl —— 通用常量与数学工具
================================================================================
 这里只放"纯函数"：不声明 uniform、不声明 varying、不读写纹理。
 因此这个文件可以被顶点着色器和片元着色器同时安全地 include。

 命名约定（整个项目统一遵守）：
   - 变量、函数：lowerCamelCase
   - 宏（#define）：UPPER_SNAKE_CASE
   - 顶点属性：GLSL 120 兼容程序使用 gl_* 内置属性
   - uniform：不加前缀，直接用 OptiFine 提供的名字
   - varying：v 开头
   - 材质/枚举：MAT_ 开头
================================================================================
*/
#ifndef LIB_COMMON_GLSL
#define LIB_COMMON_GLSL

/* ---------------------------------------------------------------------------
 * 常量
 * ------------------------------------------------------------------------ */

// 圆周率。GLSL 没有内置的 PI，必须自己定义。
#define PI 3.141592653589793
#define TAU 6.283185307179586

// 半个圆周率，用于把 [-1,1] 映射到 [0,PI] 之类的场景。
#define HALF_PI 1.570796326794897

// 极小值。用来避免除零、以及作为浮点数比较的容差。
#define EPSILON 1e-5


/* ---------------------------------------------------------------------------
 * 数学工具
 * ------------------------------------------------------------------------ */

// 平方。写成函数而不是 pow(x, 2.0)，因为 pow 内部走的是 exp/log，慢得多。
float square(float x) {
    return x * x;
}

// 四次方。常用于把 NdotL 之类的衰减曲线压得更"硬"。
float pow4(float x) {
    float x2 = x * x;
    return x2 * x2;
}

// 感知亮度（Rec.709 权重）。
// 人眼对绿色最敏感、蓝色最不敏感，所以绿色权重最大。
// 灰度化、色调映射、亮度阈值判断都要用它，不能简单取 (r+g+b)/3。
float luma(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

// 线性重映射：把 value 从 [inMin, inMax] 映射到 [outMin, outMax]。
// 不做 clamp，超出范围会外推。
float remap(float value, float inMin, float inMax, float outMin, float outMax) {
    return outMin + (value - inMin) / (inMax - inMin) * (outMax - outMin);
}

// 按亮度饱和度和插值地调整颜色的"鲜艳程度"。
// amount = 0 得到灰度，1 保持原色，> 1 会过饱和。
vec3 applySaturation(vec3 color, float amount) {
    float gray = luma(color);
    return mix(vec3(gray), color, amount);
}

// 以中灰 0.5 为轴心调整对比度。
// amount = 1 不变，> 1 更硬，< 1 更平。
vec3 applyContrast(vec3 color, float amount) {
    return (color - 0.5) * amount + 0.5;
}

// 安全归一化：向量长度接近 0 时返回 fallback。
// 直接 normalize(vec3(0)) 会得到 NaN，NaN 一旦进入光照计算就会传染，
// 表现为整块屏幕变黑或闪烁，非常难排查。
vec3 safeNormalize(vec3 v, vec3 fallback) {
    float len = length(v);
    return len > EPSILON ? v / len : fallback;
}


/* ---------------------------------------------------------------------------
 * 法线编码 / 解码
 * ------------------------------------------------------------------------ */

// G-Buffer 里只用 RG 两个 8 位通道存法线，节省带宽。
// 八面体折叠保存完整球面，保留掠射面可能为负的 z 分量。
vec2 encodeNormal(vec3 normal) {
    normal /= max(abs(normal.x) + abs(normal.y) + abs(normal.z), EPSILON);
    vec2 p = normal.xy;
    if (normal.z < 0.0) {
        p = (1.0 - abs(p.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
    }
    return p * 0.5 + 0.5;
}

vec3 decodeNormal(vec2 encoded) {
    vec2 p = encoded * 2.0 - 1.0;
    vec3 normal = vec3(p, 1.0 - abs(p.x) - abs(p.y));
    float fold = clamp(-normal.z, 0.0, 1.0);
    normal.xy += vec2(normal.x >= 0.0 ? -fold : fold, normal.y >= 0.0 ? -fold : fold);
    return normalize(normal);
}


/* ---------------------------------------------------------------------------
 * 材质标记
 *   把"这是什么物体"这条信息一路带到后处理阶段，
 *   后面想给水做屏幕空间反射、给树叶做风摆动，都靠它来区分。
 * ------------------------------------------------------------------------ */
#define MAT_SOLID   0.20
#define MAT_WATER   0.45
#define MAT_FOLIAGE 0.70
#define MAT_ENTITY  1.00
#define MAT_WET_GROUND 0.85


/* ---------------------------------------------------------------------------
 * 哈希与伪随机
 *   GLSL 没有随机数。同一个像素每帧的结果必须一致，所以只能用
 *   "位置 -> 固定数值" 的哈希函数。常用在抖动、噪波、闪烁效果上。
 * ------------------------------------------------------------------------ */

// 输入一个二维坐标，输出 [0,1) 之间的伪随机数。
// fract(sin(dot(...))) 是图形学里最经典的哈希写法，代价低且分布够用。
float hash12(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// 输入三维坐标，输出 [0,1) 之间的伪随机数。
float hash13(vec3 p) {
    return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

#endif  // LIB_COMMON_GLSL
