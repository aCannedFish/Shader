/*
================================================================================
 settings.glsl —— 全局设置
================================================================================
 这个文件把所有可调参数集中到一处，被每个 .vsh / .fsh 通过 #include 引入。

 两类参数：
   1. const 常量：OptiFine 内置识别的 "Shader Constants"，会在光影设置界面
      自动生成对应的滑块（例如 shadowMapResolution、shadowDistance）。
      值必须在所有程序中保持一致，所以只能写在这里。
   2. #define 宏：我们自己定义的开关/数值。OptiFine 会扫描源码里的 #define，
      凡是能在 shaders.properties 中找到同名 option.X 的，就会变成界面上的
      按钮或滑块，并且界面里改的值会【直接写回本文件的这一行】。
      所以 #ifndef 只是为了在第一次运行时提供默认值。

 修改建议：优先在游戏内改；手改文件时不要删掉 #define 这一行本身。
================================================================================
*/
#ifndef SETTINGS_GLSL
#define SETTINGS_GLSL


/* ============================================================================
 * 一、OptiFine 内置常量（会自动生成界面控件，不需要写进 shaders.properties）
 * ==========================================================================*/

// 阴影贴图分辨率（正方形边长，单位像素）。取值只能是 2 的幂。
// 越大阴影边缘越清晰，代价是显存占用和采样带宽线性增长。
const int shadowMapResolution = 2048;

// 阴影的可见距离（单位：方块）。超出这个距离的物体不投射也不接收阴影。
// 阴影贴图是一张正交投影图，覆盖范围越大，同样分辨率下每个像素代表的
// 实际面积就越大，阴影就越糊 —— 这是分辨率与距离之间的直接权衡。
const float shadowDistance = 96.0;

// 让硬件做阴影贴图的深度比较过滤。
// 这里设为 false，因为我们要手写 PCF（百分比渐进过滤）以便教学；
// 打开后 shadowMap 会被绑定成深度比较纹理，texture2D 的返回值语义会变。
const bool shadowHardwareFiltering = false;

// 太阳轨迹倾斜角（度）。0 表示太阳从正东升起、正西落下。
// 非 0 值会让太阳轨迹绕摄像机 Z 轴旋转，可以让阴影方向更好看。
const float sunPathRotation = 0.0;

// 噪声纹理的分辨率（OptiFine 自动生成一张随机纹理并绑定到 noisetex）。
const int noiseTextureResolution = 64;


/* ============================================================================
 * 二、颜色缓冲区的格式与清除行为
 *    OptiFine 允许对每张 colortex 分别设置：格式、是否每帧清除、是否生成 mipmap
 *
 *  ⚠️ 格式声明为什么必须包在块注释里？
 *     `RGBA16F` 这类写法是 OptiFine 自己的语法，【不是合法的 GLSL】。
 *     OptiFine 解析时扫的是文件里的原始文本行（注释里的内容它一样能读到），
 *     但 GLSL 编译器认不出 RGBA16F，会直接报
 *         ERROR: Use of undeclared identifier 'RGBA16F'
 *     然后整个程序链接失败（表现为画面只剩天空、地形消失）。
 *
 *     所以写法是：
 *        格式  const int  colortexNFormat = XXXXX;  -> 必须注释掉
 *        清除  const bool colortexNClear  = true;   -> 不用注释，true/false 是合法 GLSL
 *
 *     这是所有成熟光影包（BSL、Complementary 等）的通行做法。
 *     想让某张缓冲区改用别的格式，改注释里的值即可，不用把注释去掉。
 * ==========================================================================*/

/*
// colortex0：场景颜色。用 16 位浮点保存，才能存下大于 1.0 的高光值，
// 后面的色调映射（tone mapping）才有意义。若用 RGBA8，超过 1.0 会被直接截断。
const int colortex0Format = RGBA16F;

// colortex1：几何缓冲区 G-Buffer —— 法线 + 材质标记。0~1 的普通数据，8 位够用。
const int colortex1Format = RGBA8;

// colortex2：光照缓冲区 —— 方块光、天空光、阴影系数。
const int colortex2Format = RGBA8;

// colortex3：泛光（bloom）的亮部提取结果。需要 HDR，所以也是浮点。
const int colortex3Format = RGBA16F;

// colortex4：泛光的模糊结果。同样需要 HDR。
// （之所以要两张泛光缓冲，是因为"不能在同一次绘制里既读又写同一张纹理"，
//   亮部提取写到 3，模糊结果写到 4，最后一个程序再合并。）
const int colortex4Format = RGBA16F;
*/

const bool colortex0Clear = true;
const bool colortex1Clear = true;
const bool colortex2Clear = true;
const bool colortex3Clear = true;
const bool colortex4Clear = true;


/* ============================================================================
 * 三、阴影设置
 * ==========================================================================*/

// 总开关。0 = 关闭阴影（同时省掉整个 shadow 渲染通道），1 = 开启。
#ifndef ENABLE_SHADOWS
#define ENABLE_SHADOWS 1
#endif

// PCF 采样半径（单位：阴影贴图像素）。0 = 只采 1 个点（最硬），
// 1 = 3x3 共 9 个点，2 = 5x5 共 25 个点。越大越柔和也越慢。
#ifndef SHADOW_SOFTNESS
#define SHADOW_SOFTNESS 1
#endif

// 阴影贴图的畸变强度。OptiFine 的阴影贴图是正交投影，覆盖整个 shadowDistance
// 范围，如果纹素均匀分布，近处会显得很糊。畸变把纹素向中心（近处）集中，
// 让脚下的阴影更清晰、远处的更糊 —— 这正好符合人眼的关注习惯。
//
//   0.0 = 不做畸变（纹素均匀分布）
//   0.9 = 常用值（推荐）
//   1.0 = 退化成全屏塌缩，【不要用】
#ifndef SHADOW_MAP_BIAS
#define SHADOW_MAP_BIAS 0.9
#endif

// 深度偏移，用来消除"阴影痤疮"（shadow acne，表面出现条纹状自阴影）。
// 实际使用的偏移会随光线入射角变化，见 lib/shadow.glsl。
#ifndef SHADOW_BIAS
#define SHADOW_BIAS 0.00035
#endif


/* ============================================================================
 * 四、光照强度
 * ==========================================================================*/

// 环境光（来自光照贴图的方块光/天空光）的整体亮度倍率。
#ifndef AMBIENT_STRENGTH
#define AMBIENT_STRENGTH 1.0
#endif

// 直射阳光（月亮）的亮度倍率。
#ifndef SUNLIGHT_STRENGTH
#define SUNLIGHT_STRENGTH 1.0
#endif

// 环境光的染色强度。0 = 环境光完全使用光照贴图自带的颜色，
// 1 = 环境光完全使用天空颜色。中间值做插值。
#ifndef SKY_TINT
#define SKY_TINT 0.35
#endif

// 日光颜色：太阳高度角越低越暖（红/橙），正午接近白色。
#ifndef SUN_COLOR_DAY
#define SUN_COLOR_DAY 1.0
#endif


/* ============================================================================
 * 五、雾与大气
 * ==========================================================================*/

// 雾浓度倍率。1.0 = 雾从约 60% 视距处开始出现，到视距尽头完全遮蔽。
#ifndef FOG_DENSITY
#define FOG_DENSITY 1.0
#endif

// 水面波浪：顶点动画 + 法线扰动。0 = 静止水面（省性能），1 = 开启。
#ifndef ENABLE_WATER_WAVES
#define ENABLE_WATER_WAVES 1
#endif


/* ============================================================================
 * 六、后处理
 * ==========================================================================*/

// 色调映射曲线。0 = 不处理（直接截断，容易死白），
// 1 = ACES 近似（电影感，推荐），2 = Reinhard（简单，对比度低）。
#ifndef TONEMAP_MODE
#define TONEMAP_MODE 1
#endif

// 曝光。整体亮度的乘数，在色调映射之前作用。
#ifndef EXPOSURE
#define EXPOSURE 1.0
#endif

// 饱和度。1.0 = 不变，<1 变灰，>1 变艳。
#ifndef SATURATION
#define SATURATION 1.05
#endif

// 对比度。以中灰 0.5 为中心拉伸。1.0 = 不变。
#ifndef CONTRAST
#define CONTRAST 1.0
#endif

// 暗角强度。0 = 关闭，0.3 = 轻微。屏幕四角压暗。
#ifndef VIGNETTE
#define VIGNETTE 0.15
#endif

// 泛光总开关。
#ifndef ENABLE_BLOOM
#define ENABLE_BLOOM 1
#endif

// 泛光亮度阈值：只有亮度超过这个值的像素才会发光溢出。
#ifndef BLOOM_THRESHOLD
#define BLOOM_THRESHOLD 0.85
#endif

// 泛光强度：叠加回原图时的倍率。
#ifndef BLOOM_STRENGTH
#define BLOOM_STRENGTH 0.25
#endif

// 泛光模糊半径（屏幕宽度的百分比）。
#ifndef BLOOM_RADIUS
#define BLOOM_RADIUS 1.0
#endif

// 抖动（dither）。用噪声打散色带，避免天空等渐变区域出现条纹。
#ifndef ENABLE_DITHER
#define ENABLE_DITHER 1
#endif

// 抖动强度。1.0/255.0 表示 1 个色阶左右。
#ifndef DITHER_STRENGTH
#define DITHER_STRENGTH 1.0
#endif


/* ============================================================================
 * 七、调试视图
 *    开发期最常用的功能：把中间结果直接画到屏幕上。
 *    这是排查"颜色不对/阴影不对"最快的手段，强烈建议保留。
 * ==========================================================================*/

// 0 = 关闭（正常画面）
// 1 = 视图空间法线
// 2 = 光照贴图坐标
// 3 = 阴影系数（黑 = 被遮挡，白 = 受光）
// 4 = 深度缓冲（越远越白）
// 5 = 泛光缓冲
// 6 = 视图空间坐标
#ifndef DEBUG_VIEW
#define DEBUG_VIEW 0
#endif


#endif  // SETTINGS_GLSL
