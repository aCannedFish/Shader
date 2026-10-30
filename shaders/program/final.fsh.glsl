#define SIMPLE_VARYING in
layout(location=0) out vec4 fullOut0;
layout(location=1) out vec4 fullOut1;
layout(location=2) out vec4 fullOut2;
layout(location=3) out vec4 fullOut3;
layout(location=4) out vec4 fullOut4;

/* 最终输出。轻度径向色差、泛光与太阳镜头光晕先在线性空间合成，
 * 再应用夜间曝光、色调映射和颜色调整，最后编码到显示空间。
 * 调试视图可替换最终颜色输出。
 */

/* 全局渲染设置。集中定义加载器常量、缓冲格式和可调宏；各程序共享同一组默认值。
 * 游戏内选项由 shaders.properties 分组，用户选择由加载器保存。
 */
#include "/settings.glsl"

/* 加载器输入声明。集中定义相机、时间、天气、光照、深度与视图/阴影矩阵 uniform。
 */
#ifndef LIB_UNIFORMS_GLSL
#define LIB_UNIFORMS_GLSL


/* ============================================================================
 * 一、玩家摄像机的矩阵（gbuffer 系列）
 * ==========================================================================*/

// 世界空间 -> 视图空间。摄像机在原点，看向 -Z，+Y 朝上。
uniform mat4 gbufferModelView;

// 视图空间 -> 世界空间（摄像机相对）。提取法线方向时可以用 mat3() 取左上角。
uniform mat4 gbufferModelViewInverse;

// 视图空间 -> 裁剪空间（透视投影）。
uniform mat4 gbufferProjection;

// 裁剪空间 -> 视图空间。从深度缓冲还原真实坐标时必用。
uniform mat4 gbufferProjectionInverse;

// 上一帧的同名矩阵。做运动模糊、TAA、时域降噪时需要，
// 本基础光影暂时用不到，先声明出来方便后续扩展。
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

// Native OptiFine J9: terrain is 8 (solid), 9 (cutout), 16 (translucent).
// Entities=10, block entities=11 and solid hand=15 are separate geometry paths.
uniform int renderStage;


/* ============================================================================
 * 二、阴影摄像机的矩阵（shadow 系列）
 *    阴影贴图由"站在太阳位置"的虚拟摄像机渲染，它有独立的一套矩阵。
 *    把世界坐标乘上 shadowModelView * shadowProjection，就得到该点
 *    在太阳眼中的位置，进而算出阴影贴图上的采样坐标。
 * ==========================================================================*/

uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowProjectionInverse;


/* ============================================================================
 * 三、摄像机与屏幕
 * ==========================================================================*/

// 摄像机的【绝对世界坐标】。视图空间坐标 + cameraPosition = 绝对世界坐标。
uniform vec3 cameraPosition;

// 上一帧的摄像机位置，同样为扩展预留。
uniform vec3 previousCameraPosition;

// 投影的近平面 / 远平面距离（单位：方块）。
// far 等于游戏设置里的渲染距离，是自定义雾的核心参数。
uniform float near;
uniform float far;

// 内部场景纹理分辨率（像素）与宽高比。final 的输出窗口可以是另一尺寸。
uniform float viewWidth;
uniform float viewHeight;
uniform float aspectRatio;

// 中心深度（屏幕正中央像素的深度），做自动对焦/景深时用。
uniform float centerDepthSmooth;


/* ============================================================================
 * 四、时间
 * ==========================================================================*/

// 当前游戏内时间，范围 [0, 24000)。0 = 日出，6000 = 正午，18000 = 日落。
uniform int worldTime;

// 累计游戏天数，可用来做"每天不一样"的随机。
uniform int worldDay;

// 从世界创建起累计的秒数（浮点）。做周期性动画（水波、闪烁）时用它，
// 比 worldTime 更平滑，因为它是连续的浮点而不是整数 tick。
uniform float frameTimeCounter;
// 每帧秒数用于介质状态的时间平滑，响应速度不依赖帧率。
uniform float frameTime;

// 已渲染的帧数。做抖动（dither）时用它让每帧噪声不同。
uniform int frameCounter;


/* ============================================================================
 * 五、光照与天空
 * ==========================================================================*/

// 太阳 / 月亮在【视图空间】中的位置，长度约为 100。
// 用 normalize() 之后即可当作"从表面指向光源"的方向向量。
uniform vec3 sunPosition;
uniform vec3 moonPosition;

// 世界空间的"正上方"方向在视图空间中的表示。
// 想判断"这个东西是不是朝上的"时用得到（比如让草顶面更亮）。
uniform vec3 upPosition;

// 天顶颜色，随时间和天气变化；地平线颜色由 fogColor 提供。
uniform vec3 skyColor;

// 当前"投出阴影的光源"在视图空间中的位置（白天是太阳，夜晚是月亮）。
uniform vec3 shadowLightPosition;

// 月相，0 = 满月 …… 4 = 新月。可用于调整夜晚亮度。
uniform int moonPhase;


/* ============================================================================
 * 六、天气与环境
 * ==========================================================================*/

// 雨的强度，范围 [0,1]。0 = 晴天，1 = 暴雨。
uniform float rainStrength;

// 地表湿度，范围 [0,1]。下雨时会逐渐升高，雨停后缓慢下降。
// 常用于让方块表面变暗、变光滑。
uniform float wetness;

// 摄像机的高度（y 坐标）。可以做"越高越亮"的大气效果。
uniform float eyeAltitude;

// 摄像机所处位置的平滑亮度，x 为方块光，y 为天空光。
// 类型与 OptiFine 保持一致；使用时再按需归一化到 [0,1]。
uniform ivec2 eyeBrightnessSmooth;

// 摄像机是否在液体/方块内：0 = 空气，1 = 水，2 = 岩浆，3 = 细雪。
uniform int isEyeInWater;

// 地平线雾色是 RGB 三分量。必须与 OptiFine 的 uniform 类型一致；
// 声明成 vec4 会让 glUniform3f 产生 GL_INVALID_OPERATION，雾色无法更新。
uniform vec3 fogColor;
uniform float fogDensity;

// 屏幕亮度、夜视、失明等状态效果。
uniform float screenBrightness;
uniform float nightVision;
uniform float blindness;


/* ============================================================================
 * 七、渲染状态
 * ==========================================================================*/

// 当前程序的 alpha 测试阈值。
// 贴图 alpha 小于它的像素会被丢弃。
// 对于不透明程序，这个值是游戏设置里的"树叶/草透明"相关阈值；
// 对于 _a（半透明）程序，OptiFine 会把它设为 0，于是不会误丢像素。
uniform float alphaTestRef;

// 实体着色（受伤变红等）的叠加颜色。
uniform vec4 entityColor;

// 当前绑定的方块图集大小（单位：像素），做像素级贴图操作时需要。
uniform ivec2 atlasSize;


#endif  // LIB_UNIFORMS_GLSL

/*
================================================================================
 lib/common.glsl —— 通用常量与数学工具
================================================================================
 这里只放"纯函数"：不声明 uniform、不声明 SIMPLE_VARYING、不读写纹理。
 因此这个文件可以被顶点着色器和片元着色器同时安全地 include。

 命名约定（整个项目统一遵守）：
   - 变量、函数：lowerCamelCase
   - 宏（#define）：UPPER_SNAKE_CASE
   - 顶点属性：GLSL 120 兼容程序使用 gl_* 内置属性
   - uniform：不加前缀，直接用 OptiFine 提供的名字
   - SIMPLE_VARYING：v 开头
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

/* 坐标变换。统一视图、相机相对世界、绝对世界、投影和阴影空间的转换约定。
 */
#ifndef LIB_SPACE_GLSL
#define LIB_SPACE_GLSL






/* ---------------------------------------------------------------------------
 * 视图空间 <-> 世界空间
 * ------------------------------------------------------------------------ */

// 视图空间 -> 世界空间（结果以摄像机为原点，即"摄像机相对世界坐标"）。
// 注意这个结果不是绝对世界坐标，想拿绝对坐标还要再加 cameraPosition。
vec3 viewToWorld(vec3 viewPos) {
    return (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
}

// 视图空间 -> 绝对世界坐标。
// cameraPosition 是摄像机的绝对位置，两者相加才得到 Minecraft 世界里的真实坐标。
vec3 viewToAbsoluteWorld(vec3 viewPos) {
    return viewToWorld(viewPos) + cameraPosition;
}

// 世界空间（摄像机相对） -> 视图空间
vec3 worldToView(vec3 worldPos) {
    return (gbufferModelView * vec4(worldPos, 1.0)).xyz;
}


/* ---------------------------------------------------------------------------
 * 深度
 *   depthtex0 里存的深度是非线性的：经过透视投影后，近处精度极高，
 *   远处精度极低（这就是"z-fighting"的根源）。想拿真实距离必须还原。
 * ------------------------------------------------------------------------ */

// 把 [0,1] 的深度缓冲值还原成视图空间的线性距离（单位：方块）。
// 公式来源：把 NDC 深度代回投影矩阵的逆推导，适用于标准透视投影。
float linearizeDepth(float depth) {
    float ndcDepth = depth * 2.0 - 1.0;             // [0,1] -> [-1,1]
    return (2.0 * near * far) / (far + near - ndcDepth * (far - near));
}

// 由屏幕 UV + 深度缓冲值还原视图空间坐标。
// 这是屏幕空间效果（SSAO、屏幕空间反射、体积光）的第一步。
vec3 screenToView(vec2 uv, float depth) {
    // UV [0,1] 先变回 NDC [-1,1]
    vec4 ndc = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 viewPos = gbufferProjectionInverse * ndc;
    return viewPos.xyz / viewPos.w;                 // 透视除法，还原到真实位置
}


/* ---------------------------------------------------------------------------
 * 屏幕坐标工具
 *
 * ⚠️ 注意：本文件会被【顶点着色器】一起包含（顶点变换也要用矩阵）。
 *    所以这里绝不能出现 gl_FragCoord / gl_FragData 这类片元专用的内置变量，
 *    否则顶点着色器会直接编译失败。
 *    内部全分辨率阶段的 UV 因此在对应 .fsh 里现算：
 *        vec2 screenCoord = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
 *    final 输出到窗口，必须使用顶点传入的归一化 UV；加载器的
 *    渲染精细度会使窗口尺寸与 viewWidth/Height 不同。
 * ------------------------------------------------------------------------ */

// 像素尺寸：一个像素在 UV 空间中的大小，采样邻域时用。
vec2 getTexelSize() {
    return 1.0 / vec2(viewWidth, viewHeight);
}

// 做模糊/泛光时，需要用宽高比校正采样偏移，
// 否则在宽屏上圆形核会被拉成椭圆。
vec2 aspectCorrect(vec2 offset) {
    return offset * vec2(1.0, viewWidth / viewHeight);
}


/* ---------------------------------------------------------------------------
 * 阴影贴图畸变
 *   阴影贴图是正交投影，覆盖了 shadowDistance 范围内的一个方盒子。
 *   离摄像机越远的地方，一个纹素覆盖的实际面积越大（近处很精细，
 *   远处很粗糙）。把裁剪空间坐标按距离向外拉伸，等于把纹素"重新分配"：
 *   近处纹理占用变多、远处占用变少，整体精度更均匀。
 *
 *   注意：顶点着色器和片元着色器必须用完全相同的畸变函数，
 *   否则投影出来的位置和采样的位置对不上，阴影会整体错位。
 * ------------------------------------------------------------------------ */
// 加载器会缩放阴影附件，并将尺寸四舍五入到整数纹素。
float shadowTextureResolution() {
#ifdef MC_SHADOW_QUALITY
    return max(floor(float(shadowMapResolution) * MC_SHADOW_QUALITY + 0.5), 1.0);
#else
    return float(shadowMapResolution);
#endif
}

vec3 distortShadow(vec3 clipPos) {
    float dist = length(clipPos.xy);                // 距离屏幕中心的距离，范围约 [0, 1.41]
    // ---------------------------------------------------------------
    // factor = (1 - BIAS) + dist * BIAS
    //
    //   BIAS = 0.0  -> factor 恒等于 1        -> xy 不变，【不畸变】
    //   BIAS = 0.9  -> 中心 factor = 0.1，边缘 factor = 1.0
    //                  xy 被除以一个小数 -> 中心附近的坐标被推向边缘
    //                  -> 贴图中心区域占用的纹素变多（近处更精细）✅
    //   BIAS = 1.0  -> factor = dist，除以它会得到单位向量
    //                  -> 【退化成全屏塌缩】，不要用这个值
    //
    // 所以 BIAS 越大畸变越强，常用 0.9，取值必须小于 1。
    // ---------------------------------------------------------------
    float factor = (1.0 - SHADOW_MAP_BIAS) + dist * SHADOW_MAP_BIAS;
    clipPos.xy /= factor;
    return clipPos;
}

// 将阴影纹素中心反解到未畸变的裁剪平面，供光栅深度校正使用。
vec2 undistortShadow(vec2 distorted) {
    float denominator = max(1.0 - SHADOW_MAP_BIAS * length(distorted), EPSILON);
    return distorted * (1.0 - SHADOW_MAP_BIAS) / denominator;
}

// 把畸变后的裁剪空间坐标转成可以直接采样的 UV + 深度。
// 透视除法在这里显式做，因为畸变是在除法【之前】施加的。
vec3 shadowClipToUv(vec4 shadowClipPos) {
    vec3 ndc = shadowClipPos.xyz / shadowClipPos.w; // 裁剪空间 -> NDC [-1,1]
    return ndc * 0.5 + 0.5;                         // NDC -> [0,1]，同时得到 UV 和深度
}

#endif  // LIB_SPACE_GLSL

/* HDR 亮度映射与色域约束。保持中间调的色相，控制曝光、饱和度、对比度与显示编码。
 */
#ifndef LIB_TONEMAP_GLSL
#define LIB_TONEMAP_GLSL





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





// OptiFine 自动生成的随机噪声纹理，三个通道各自独立随机。
/* Shared sampler for the packed periodic cloud volume and lunar albedo. */
#ifndef LIB_SKY_NOISE_GLSL
#define LIB_SKY_NOISE_GLSL
uniform sampler2D noisetex;
#endif



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
    return texture(noisetex, noiseCoord).r;
}

#endif  // LIB_NOISE_GLSL

/* HDR 泛光：先逐样本提取亮部再降采样，随后执行可分离过滤。
 * 缓冲只使用左下有效视口，所有读取限制到有效纹素中心，避免采到旧天空/体积场。
 * 阈值和峰值限制先于平均，保留细小光源并抑制极亮像素的闪烁。
 */
#ifndef LIB_BLOOM_GLSL
#define LIB_BLOOM_GLSL




vec2 bloomSize() {
#if BLOOM_RESOLUTION == 0
    return max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
#else
    return vec2(viewWidth, viewHeight);
#endif
}

// 输入为全屏归一化坐标；返回当前泛光视口内的纹理坐标。
vec2 bloomUv(vec2 uv) {
    vec2 size = bloomSize();
    return clamp(uv * size, vec2(0.5), size - 0.5) / vec2(viewWidth, viewHeight);
}

vec3 extractBloom(vec3 color) {
    float brightness = luma(color);
    float knee = max(BLOOM_THRESHOLD * 0.5, 0.001);
    float soft = clamp(brightness - BLOOM_THRESHOLD + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee);
    float energy = min(max(soft, brightness - BLOOM_THRESHOLD), 6.0);
    return color * max(energy, 0.0) / max(brightness, EPSILON);
}

// 半分辨率下覆盖输出像素的四个象限，先提亮部再平均，避免小火把被阈值吞掉。
vec3 prefilterBloom(sampler2D source, vec2 uv) {
#if ENABLE_BLOOM == 0
    return vec3(0.0);
#elif BLOOM_RESOLUTION == 0
    vec2 pixel = 1.0 / vec2(viewWidth, viewHeight);
    vec2 offset = 0.25 / bloomSize();
    vec3 sum = vec3(0.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 sampleUv = clamp(uv + (vec2(float(x), float(y)) * 2.0 - 1.0) * offset,
                                  pixel * 0.5, 1.0 - pixel * 0.5);
            sum += extractBloom(texture(source, sampleUv).rgb);
        }
    }
    return sum * 0.25;
#else
    return extractBloom(texture(source, uv).rgb);
#endif
}

// 对称 13 点高斯核的相邻权重配对，借助线性纹理过滤用 7 次读取近似。
// 半径按场景像素定义，不随泛光档位改变；核权重归一化，不额外放大能量。
vec3 filterBloom(sampler2D source, vec2 uv, vec2 axis) {
#if ENABLE_BLOOM == 0
    return vec3(0.0);
#else
    float spacing = min(1.5 * BLOOM_RADIUS * min(viewWidth, viewHeight) / 1080.0, 2.0);
    vec2 stepUv = axis * spacing / vec2(viewWidth, viewHeight);
    vec3 sum = texture(source, bloomUv(uv)).rgb * 0.161003374;
    sum += (texture(source, bloomUv(uv + stepUv * 1.440286351)).rgb
          + texture(source, bloomUv(uv - stepUv * 1.440286351)).rgb) * 0.265537291;
    sum += (texture(source, bloomUv(uv + stepUv * 3.363547460)).rgb
          + texture(source, bloomUv(uv - stepUv * 3.363547460)).rgb) * 0.123133699;
    sum += (texture(source, bloomUv(uv + stepUv * 5.293177779)).rgb
          + texture(source, bloomUv(uv - stepUv * 5.293177779)).rgb) * 0.030827323;
    return sum;
#endif
}
#endif


// 场景颜色（所有 gbuffers 程序的输出，包含半透明物体）
uniform sampler2D colortex0;

// 模糊后的泛光
uniform sampler2D colortex3;

// 下面这几个是 lib/debug.glsl 的调试视图要用的。
// 该文件自己不声明采样器（因为它被不同程序共用，能读到的纹理不一样），
// 所以在这里统一声明。用不到的调试视图会被编译器优化掉。
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D depthtex0;

/* 调试输出。按 DEBUG_VIEW 显示法线、光照贴图、阴影、深度、泛光或重建视图坐标。
 */
#ifndef LIB_DEBUG_GLSL
#define LIB_DEBUG_GLSL






/* 本文件【不声明】任何采样器，因为不同程序要读的纹理不一样。
 * 调用方必须先自行声明下面这些（用不到的可以不声明，
 * 但那样就不能启用对应的调试视图）：
 *
 *   uniform sampler2D depthtex0;   深度缓冲，[0,1] 非线性深度
 *   uniform sampler2D colortex1;   r,g = 八面体法线编码，b = 天空光，a = 材质
 *   uniform sampler2D colortex2;   r = 方块光，g = 天空光，b = 阴影系数
 *   uniform sampler2D colortex3;   最终泛光；调用方同时包含 bloom.glsl 进行视口映射
 */


/* ---------------------------------------------------------------------------
 * 主分发函数
 *   color        已经算完的正常画面颜色
 *   screenCoord  当前像素的屏幕 UV [0,1]
 *   返回：调试开启时返回调试颜色，关闭时原样返回 color
 * ------------------------------------------------------------------------ */
vec3 applyDebugView(vec3 color, vec2 screenCoord) {
#if DEBUG_VIEW == 0
    return color;
#else
    // 采样三张 G-Buffer，按需取用。
    vec4 geomBuffer = texture(colortex1, screenCoord);
    vec4 lightBuffer = texture(colortex2, screenCoord);

    #if DEBUG_VIEW == 1
        // 视图空间法线，八面体编码在 RG 两个通道里（见 lib/common.glsl 的 encodeNormal）
        vec3 normal = decodeNormal(geomBuffer.rg);
        // 映射到 [0,1] 方便观察：朝右 = 红，朝上 = 绿，朝摄像机 = 蓝
        return normal * 0.5 + 0.5;

    #elif DEBUG_VIEW == 2
        // 光照贴图坐标：r = 方块光，g = 天空光
        return vec3(lightBuffer.r, lightBuffer.g, 0.0);

    #elif DEBUG_VIEW == 3
        // 阴影系数：白 = 受光，黑 = 被遮挡
        return vec3(lightBuffer.b);

    #elif DEBUG_VIEW == 4
        // 原始深度缓冲，直接可视化（近处黑、远处白）
        // 想看得更清楚可以换成 linearizeDepth(...) / far
        float depth = texture(depthtex0, screenCoord).r;
        return vec3(depth);

    #elif DEBUG_VIEW == 5
        // 泛光缓冲
        return texture(colortex3, bloomUv(screenCoord)).rgb;

    #elif DEBUG_VIEW == 6
        // 由深度还原视图空间坐标，可视化 xyz。
        // 这是在为 SSAO / 屏幕空间反射做准备，能直观确认坐标还原是否正确。
        float depth = texture(depthtex0, screenCoord).r;
        vec3 viewPos = screenToView(screenCoord, depth);
        return abs(viewPos) / far;

    #else
        return color;
    #endif
#endif
}

#endif  // LIB_DEBUG_GLSL

/* 镜头光学近似：太阳的遮挡感知光晕与轻度径向色差。
 * 光晕亮度只在亮部阶段的首个纹素计算一次，再通过附件 alpha 传递。
 */
#ifndef LIB_LENS_OPTICS_GLSL
#define LIB_LENS_OPTICS_GLSL





vec2 lensSunUv() {
    vec4 projected = gbufferProjection * vec4(normalize(sunPosition), 0.0);
    return projected.xy / max(projected.w, EPSILON) * 0.5 + 0.5;
}

// 九点覆盖太阳圆盘。深度拒绝实体遮挡，实际 HDR 亮度同时限制云层和浓雾中的光晕。
float lensSunVisibility(sampler2D scene, sampler2D depths) {
#if ENABLE_LENS_FLARE == 0 || SIMPLE_DIMENSION != 0
    return 0.0;
#else
    vec3 direction = normalize(sunPosition);
    vec3 world = mat3(gbufferModelViewInverse) * direction;
    vec2 center = lensSunUv();
    float edge = min(min(center.x, center.y), min(1.0 - center.x, 1.0 - center.y));
    if (LENS_FLARE_STRENGTH <= 0.0 || isEyeInWater != 0
        || direction.z >= -0.05 || world.y <= 0.0 || edge <= 0.0) {
        return 0.0;
    }
    vec3 right = normalize(cross(direction, vec3(0.0, 1.0, 0.0)));
    vec3 up = cross(right, direction);
    float sum = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec3 ray = direction + (right * float(x) + up * float(y))
                     * (0.075 * CELESTIAL_SIZE * 0.55);
            vec4 clip = gbufferProjection * vec4(ray, 0.0);
            vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
            if (all(greaterThan(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)))) {
                float sky = step(0.999999, texture(depths, uv).r);
                float bright = smoothstep(0.8, 2.5, luma(texture(scene, uv).rgb));
                sum += sky * bright;
            }
        }
    }
    return sum / 9.0 * smoothstep(0.0, 0.06, edge) * smoothstep(0.0, 0.06, world.y);
#endif
}

// 平滑、有限范围的镀膜鬼影，避免硬圆边与整屏雾状增亮。
float lensGhost(vec2 uv, vec2 center, float radius) {
    vec2 offset = (uv - center) * vec2(aspectRatio, 1.0);
    float weight = max(1.0 - dot(offset, offset) / (radius * radius), 0.0);
    return weight * weight * weight;
}

vec3 lensFlare(vec2 uv, float visibility) {
#if ENABLE_LENS_FLARE == 0
    return vec3(0.0);
#else
    if (visibility <= 0.0 || LENS_FLARE_STRENGTH <= 0.0) {
        return vec3(0.0);
    }
    vec2 source = lensSunUv();
    vec2 axis = source - 0.5;
    float separation = smoothstep(0.0, 0.10, length(axis));
    vec3 ghosts = vec3(0.45, 0.75, 0.65) * 1.00
                * lensGhost(uv, vec2(0.5) - axis * 0.45, 0.045);
    ghosts += vec3(0.90, 0.55, 0.30) * 0.40
            * lensGhost(uv, vec2(0.5) - axis * 0.95, 0.075);
    vec2 offset = (uv - source) * vec2(aspectRatio, 1.0);
    vec2 line = max(vec2(1.0) - abs(offset) / 0.0015, vec2(0.0));
    float glint = dot(line, line) / (1.0 + dot(offset, offset) * 400.0);
    vec3 tint = mix(vec3(1.0, 0.65, 0.32), vec3(1.0, 0.95, 0.85),
                    smoothstep(0.05, 0.60, (mat3(gbufferModelViewInverse)
                        * normalize(sunPosition)).y));
    return (ghosts * separation + tint * glint * 0.12)
         * visibility * LENS_FLARE_STRENGTH;
#endif
}

// 中心保持清晰，向角落逐渐增加红蓝通道的相反偏移；边界采样始终留在图内。
vec3 sampleChromaticScene(sampler2D scene, vec2 uv) {
    vec3 color = texture(scene, uv).rgb;
#if ENABLE_CHROMATIC_ABERRATION == 1
    if (CHROMATIC_ABERRATION_STRENGTH > 0.0) {
        vec2 radial = (uv - 0.5) * vec2(aspectRatio, 1.0);
        float squared = dot(radial, radial);
        float edge = squared / (0.25 * (aspectRatio * aspectRatio + 1.0));
        vec2 pixels = radial / max(sqrt(squared), EPSILON) * edge * edge
                    * CHROMATIC_ABERRATION_STRENGTH * min(viewWidth, viewHeight) / 1080.0;
        vec2 size = vec2(viewWidth, viewHeight);
        vec2 offset = pixels / size;
        color.r = texture(scene, clamp(uv + offset, 0.5 / size, 1.0 - 0.5 / size)).r;
        color.b = texture(scene, clamp(uv - offset, 0.5 / size, 1.0 - 0.5 / size)).b;
    }
#endif
    return color;
}
#endif


SIMPLE_VARYING vec2 vScreenUv;

void main() {
    // final 的视口是输出窗口；viewWidth/Height 仍表示内部纹理尺寸。
    vec2 screenCoord = vScreenUv;

    /* -----------------------------------------------------------------------
     * 第一步：取出场景颜色
     * -------------------------------------------------------------------- */
    vec3 color = sampleChromaticScene(colortex0, screenCoord);

    /* -----------------------------------------------------------------------
     * 第二步：叠加泛光
     * 泛光是"额外的光"，所以是加法而不是混合。
     * BLOOM_STRENGTH 控制它有多强；太大会让画面糊成一团。
     * -------------------------------------------------------------------- */
#if ENABLE_BLOOM == 1
    vec3 bloom = texture(colortex3, bloomUv(screenCoord)).rgb;
    color += bloom * BLOOM_STRENGTH;
#endif

    float solarVisibility = texture(colortex3, vec2(0.5) / vec2(viewWidth, viewHeight)).a;
    color += lensFlare(screenCoord, solarVisibility);

    /* -----------------------------------------------------------------------
     * 第三步：色调映射（含曝光、饱和度、对比度）
     * 把可能远超 1.0 的 HDR 颜色压回 [0,1]。
     * 这是"为什么高光不会死白"的原因，详见 lib/tonemap.glsl。
     * -------------------------------------------------------------------- */
    // 夜间只抬升暗部；亮光附近逐渐回到基础曝光，避免整片照明被一起放大。
    vec3 sunWorld = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    float night = 1.0 - smoothstep(-0.16, 0.12, sunWorld.y);
#if SIMPLE_DIMENSION != 0
    night = 0.0;
#endif
    // 有理衰减使最终亮度保持单调，较大的用户曝光值也不会形成反向光圈。
    float shadowLift = 0.04 / (0.04 + max(luma(color), 0.0));
    color *= mix(1.0, NIGHT_EXPOSURE, night * shadowLift);
    color = applyTonemap(color);

    /* -----------------------------------------------------------------------
     * 第四步：暗角（vignette）
     * 模拟镜头边缘进光量下降，把注意力集中到画面中心。
     * 这里在"以中心为原点"的坐标上算距离平方，再用它压暗。
     * 乘上 aspectRatio 是为了让暗角在宽屏上保持圆形而不是椭圆。
     *
     * 注意这里没有用 #if 包起来：GLSL 的预处理器只支持整数常量表达式，
     * 写 `#if VIGNETTE > 0.0` 是编译错误。好在 VIGNETTE = 0 时
     * 下面这两行的结果就是原值，等于关闭，代价可以忽略。
     * -------------------------------------------------------------------- */
    vec2 centered = (screenCoord - 0.5) * vec2(aspectRatio, 1.0);
    color *= 1.0 - VIGNETTE * dot(centered, centered) * 2.0;

    /* -----------------------------------------------------------------------
     * 第五步：线性空间 -> 显示空间
     * 把线性光强转换成显示器期望的 sRGB 信号。
     * -------------------------------------------------------------------- */
    color = toDisplaySpace(color);

    /* -----------------------------------------------------------------------
     * 第六步：抖动
     * 打散 8 位色深带来的色带。
     * 必须放在 gamma 编码【之后】，因为色带是在最终的显示值上产生的。
     * -------------------------------------------------------------------- */
    color = applyDither(color, screenCoord);

    /* -----------------------------------------------------------------------
     * 第七步：调试视图
     * 必须在最后一步，因为它要绕过上面所有处理直接显示原始数据。
     * settings.glsl 里把 DEBUG_VIEW 设成非 0 即可启用。
     * -------------------------------------------------------------------- */
    color = applyDebugView(color, screenCoord);

    /* -----------------------------------------------------------------------
     * 输出到屏幕
     * -------------------------------------------------------------------- */
    fullOut0 = vec4(color, 1.0);
}

