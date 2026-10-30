/* 全局渲染设置。集中定义加载器常量、缓冲格式和可调宏；各程序共享同一组默认值。
 * 游戏内选项由 shaders.properties 分组，用户选择由加载器保存。
 */
#ifndef SETTINGS_GLSL
#define SETTINGS_GLSL
#ifndef ENABLE_COLOURED_LIGHTING
#define ENABLE_COLOURED_LIGHTING 1 // [0 1]
#endif

// Local diffuse transport runs independently of the direct coloured-light switch.
// Quality controls propagation work per frame; reflectance controls later bounces.
#define GI_QUALITY 1 // [0 1 2 3]
#define GI_MULTIBOUNCE 1 // [0 1]

// Parenthesized expressions keep this fixed compile-time marker out of the loader option scanner.
#ifndef SIMPLE_DIMENSION
#define SIMPLE_DIMENSION (0)
#endif

// Independent environments have no solar cycle; local lights remain additive.
#define NETHER_AMBIENT 0.16 // [0.06 0.10 0.16 0.22 0.30]
#define END_AMBIENT 0.14 // [0.06 0.10 0.14 0.20 0.28]
#define NETHER_FOG_DENSITY 0.02 // [0.006 0.012 0.02 0.03 0.05]
#define END_FOG_DENSITY 0.004 // [0.002 0.004 0.008 0.012]

// Atmosphere controls. Zero strength removes the corresponding GPU contribution.
#define GROUND_FOG_STRENGTH 0.5 // [0.0 0.25 0.5 0.75 1.0]
#define GROUND_FOG_HEIGHT 8.0 // [4.0 8.0 12.0 20.0]
#define ATMOSPHERE_STEPS 6 // [6 10 16]
#define AURORA_STRENGTH 0.8 // [0.0 0.4 0.8 1.2 1.6]
#define AURORA_SPEED 1 // [0 1 2 3]
#define AURORA_STEPS 8 // [8 12 16]
#define TWILIGHT_STRENGTH 0.7 // [0.0 0.35 0.7 1.05 1.4]
#define NETHER_ATMOSPHERE 0.65 // [0.0 0.35 0.65 1.0]
#define END_ATMOSPHERE 0.65 // [0.0 0.35 0.65 1.0]

// 雨后积水与山林雨雾，强度为 0 时分别跳过对应的地表或体积计算。
#define RAIN_PUDDLES_STRENGTH 0.75 // [0.0 0.35 0.75 1.0]
#define ENABLE_REALISTIC_RAIN 1 // [0 1]
#define ENABLE_RAIN_PUDDLES 1 // [0 1]
#define RAIN_RIPPLE_STRENGTH 1.0 // [0.0 0.5 1.0 1.5]
#define RAIN_FOG_STRENGTH 1.0 // [0.0 0.5 1.0 1.5]
const float wetnessHalflife = 50.0;
const float drynessHalflife = 160.0;

// Material reflections use a separate budget from the water renderer.
#define ENABLE_MATERIAL_REFLECTIONS 1 // [0 1]
#define MATERIAL_REFLECTION_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0]
#define MATERIAL_REFLECTION_STEPS 24 // [16 24 32 48]
#define MATERIAL_GLOSS_ROUGHNESS 0.45 // [0.35 0.45 0.55 0.65]
#define MATERIAL_ANISOTROPY 0.6 // [0.0 0.3 0.6 0.8]
#define POM_QUALITY 1 // [0 1 2 3]
#define POM_DISTANCE 32.0 // [16.0 32.0 48.0 64.0]
#define ORE_GLOW_STRENGTH 0.8 // [0.0 0.4 0.8 1.2 1.6]


/* ============================================================================
 * 一、OptiFine 内置常量（会自动生成界面控件，不需要写进 shaders.properties）
 * ==========================================================================*/

// 阴影贴图分辨率（正方形边长，单位像素）。由画质预设选择，也可在阴影页单独调整。
// 越大阴影边缘越清晰，代价是显存占用和采样带宽线性增长。
const int shadowMapResolution = 1024; // [1024 2048 3072 4096]

// 阴影的可见距离（单位：方块）。超出这个距离的物体不投射也不接收阴影。
// 阴影贴图是一张正交投影图，覆盖范围越大，同样分辨率下每个像素代表的
// 实际面积就越大，阴影就越糊 —— 这是分辨率与距离之间的直接权衡。
const float shadowDistance = 64.0; // [64.0 96.0 128.0 160.0]

// 让硬件做阴影贴图的深度比较过滤。
// 使用手动深度比较、遮挡搜索和接收面斜率补偿。
// 打开后 shadowMap 会被绑定成深度比较纹理，texture2D 的返回值语义会变。
const bool shadowHardwareFiltering = false;

// 太阳轨迹倾斜角（度）。0 表示太阳从正东升起、正西落下。
// 非 0 值会让太阳轨迹绕摄像机 Z 轴旋转，可以让阴影方向更好看。
const float sunPathRotation = 0.0;

// 噪声纹理的分辨率（OptiFine 自动生成一张随机纹理并绑定到 noisetex）。
const int noiseTextureResolution = 1024;


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

// colortex1：前期为几何数据，透明阶段 RG 为水参数，BA 为独立雨层矩。
// 雨层光学深度叠加可超过 1，半浮点同时保留暗色亮度矩的精度。
const int colortex1Format = RGBA16F;

// colortex2：不透明阶段为光照数据，透明阶段保存预乘 HDR 透明颜色与覆盖率。
const int colortex2Format = RGBA16F;

// colortex3：前期天空/云查找表，后期泛光亮部与最终垂直过滤结果。
const int colortex3Format = RGBA16F;

// colortex4：前期体积场，后期泛光水平过滤。两个附件在不同通道间读写，
// 避免同一次绘制既读取又写入同一张纹理。
const int colortex4Format = RGBA16F;

// colortex9：水面八面体法线、线性深度与有效标记，需保留法线精度。
const int colortex9Format = RGBA32F;
// colortex6：deferred 保存的、不含透明水体的 HDR 场景。
const int colortex6Format = RGBA16F;
// colortex7：水的局部散射辐射与有效标记，薄层不透明度另存 colortex1.g。
const int colortex7Format = RGBA16F;
// 单纹素介质历史，只保存相机水深、天光与帧号。
const int colortex13Format = RGBA32F;
// 通用材质F0与感知粗糙度。
const int colortex14Format = RGBA16F;
// 水下出射专用的原生场景颜色；手持模型不写入，深度配对depthtex2。
const int colortex15Format = RGBA16F;
*/

const bool colortex0Clear = true;
// Opaque radiance mips retain sky coverage until deferred1 fills the background.
const vec4 colortex0ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const bool colortex1Clear = true;
const bool colortex2Clear = true;
const bool colortex3Clear = true;
const bool colortex4Clear = true;
const bool colortex9Clear = true;
const bool colortex6Clear = true;
const bool colortex7Clear = true;
const bool colortex13Clear = false;
const bool colortex14Clear = true;
const bool colortex15Clear = true;
const vec4 colortex15ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex7ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex9ClearColor = vec4(0.0, 0.0, 0.0, 0.0);


/* ============================================================================
 * 三、阴影设置
 * ==========================================================================*/

// 总开关。0 = 关闭阴影（同时省掉整个 shadow 渲染通道），1 = 开启。
#ifndef ENABLE_SHADOWS
#define ENABLE_SHADOWS 1 // [0 1]
#endif

// 方向光阴影质量。0 = 单点硬阴影；1 = 5 点遮挡搜索 + 8 点过滤，
// 2 = 9 点搜索 + 12 点过滤。无遮挡时提前结束，半影随遮挡距离增大。
#ifndef SHADOW_SOFTNESS
#define SHADOW_SOFTNESS 0 // [0 1 2]
#endif

// 阴影贴图的畸变强度。OptiFine 的阴影贴图是正交投影，覆盖整个 shadowDistance
// 范围，如果纹素均匀分布，近处会显得很糊。畸变把纹素向中心（近处）集中，
// 让脚下的阴影更清晰、远处的更糊 —— 这正好符合人眼的关注习惯。
//
//   0.0 = 不做畸变（纹素均匀分布）
//   0.9 = 常用值（推荐）
//   1.0 = 退化成全屏塌缩，【不要用】
#ifndef SHADOW_MAP_BIAS
#define SHADOW_MAP_BIAS 0.95 // [0.0 0.5 0.75 0.9 0.95]
#endif

// 深度偏移，用来消除"阴影痤疮"（shadow acne，表面出现条纹状自阴影）。
// 基础偏移受畸变与纹素大小限制；采样间的斜率由接收面补偿处理。
// 见 lib/shadow_filter.glsl。
#ifndef SHADOW_BIAS
#define SHADOW_BIAS 0.00035 // [0.0001 0.0002 0.00035 0.0005 0.001]
#endif


/* ============================================================================
 * 四、光照强度
 * ==========================================================================*/

// 天空散射和暗处基础光的倍率，局部光单独控制。
#ifndef AMBIENT_STRENGTH
#define AMBIENT_STRENGTH 0.6 // [0.4 0.6 0.8 1.0 1.2]
#endif

// 几何表面的最低环境亮度，不依赖日月或天光；0 恢复原有暗部。
#ifndef MIN_AMBIENT_LIGHT
#define MIN_AMBIENT_LIGHT 0.025 // [0.0 0.025 0.05 0.07 0.1 0.14]
#endif

// 日月直射分开调节，避免增强日光时同时把夜景照亮。
#ifndef SUNLIGHT_STRENGTH
#define SUNLIGHT_STRENGTH 1.0 // [0.0 0.4 0.6 0.8 1.0 1.2]
#endif
#ifndef MOONLIGHT_STRENGTH
#define MOONLIGHT_STRENGTH 0.03 // [0.0 0.009 0.018 0.03 0.05 0.075]
#endif
#ifndef NIGHT_AMBIENT_STRENGTH
#define NIGHT_AMBIENT_STRENGTH 0.04 // [0.0 0.02 0.04 0.06 0.08 0.12 0.16]
#endif
#ifndef NIGHT_EXPOSURE
#define NIGHT_EXPOSURE 2.0 // [1.0 1.25 1.6 2.0 2.5]
#endif

// 局部光在日照阴影之外累加；平滑采样作用于光照，不模糊材质纹理。
#ifndef BLOCK_LIGHT_STRENGTH
#define BLOCK_LIGHT_STRENGTH 1.5 // [0.0 0.5 1.0 1.5 2.0 2.5 3.0 4.0]
#endif
// 原版传播场换算为方块距离后进行有界平方衰减；6.0 对应基础校准。
// 越大则光源外围越暗，原版零光照的值和边缘斜率仍严格为零。
#ifndef BLOCK_LIGHT_FALLOFF
#define BLOCK_LIGHT_FALLOFF 4.0 // [2.0 4.0 6.0 9.0 12.0 18.0]
#endif
#ifndef SMOOTH_BLOCK_LIGHT
#define SMOOTH_BLOCK_LIGHT 1 // [0 1]
#endif
// 彩色光照：光源色调覆盖所有已加载区域（需配套 Mod），彩色玻璃给日光阴影染色，
// 发光方块以自身颜色照亮投影。关闭时统一使用原版暖色方块光和无色阴影。

// 配套 Mod 提供独立点光阴影和多次漫反射体积；缺少数据时使用原版光照。
#ifndef ENABLE_COMPANION_LIGHTING
#define ENABLE_COMPANION_LIGHTING 0 // [0 1]
#endif
#ifndef ENABLE_LOCAL_SHADOWS
#define ENABLE_LOCAL_SHADOWS 1 // [0 1]
#endif
#ifndef LOCAL_LIGHT_COUNT
#define LOCAL_LIGHT_COUNT 16 // [8 16 32 64 128]
#endif
#ifndef LOCAL_LIGHT_RADIUS
#define LOCAL_LIGHT_RADIUS 16.0 // [8.0 12.0 16.0 20.0 24.0]
#endif
#ifndef LOCAL_SHADOW_RESOLUTION
#define LOCAL_SHADOW_RESOLUTION 64 // [32 64 128 192 256]
#endif
#ifndef LOCAL_SHADOW_UPDATES
#define LOCAL_SHADOW_UPDATES 1 // [1 2 4 8 16]
#endif
#ifndef LOCAL_SHADOW_SOFTNESS
#define LOCAL_SHADOW_SOFTNESS 1.0 // [0.0 0.5 1.0 2.0 3.0]
#endif
#ifndef LOCAL_SHADOW_STRENGTH
#define LOCAL_SHADOW_STRENGTH 1.0 // [0.0 0.35 0.65 0.85 1.0]
#endif
#ifndef GI_VOLUME_SIZE
#define GI_VOLUME_SIZE 32 // [16 24 32 40 48]
#endif
#ifndef GI_BOUNCES
#define GI_BOUNCES 4 // [0 1 2 3 4 6]
#endif
#ifndef GI_PROPAGATION_STEPS
#define GI_PROPAGATION_STEPS 8 // [4 8 12 16 24]
#endif
#ifndef GI_WORK_PER_FRAME
#define GI_WORK_PER_FRAME 4 // [1 2 4 8 16]
#endif
#ifndef GI_STRENGTH
#define GI_STRENGTH 0.7 // [0.0 0.35 0.7 1.0 1.5 2.0]
#endif
#ifndef GI_REFLECTANCE
#define GI_REFLECTANCE 0.65 // [0.0 0.35 0.5 0.65 0.75 0.85]
#endif
#ifndef LIGHTING_UPDATE_INTERVAL
#define LIGHTING_UPDATE_INTERVAL 0.5 // [0.05 0.1 0.25 0.5 1.0 2.0]
#endif

// 环境光的染色强度。0 = 环境光完全使用光照贴图自带的颜色，
// 1 = 环境光完全使用天空颜色。中间值做插值。
#ifndef SKY_TINT
#define SKY_TINT 0.35 // [0.0 0.15 0.35 0.5 0.75]
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
#define FOG_DENSITY 1.0 // [0.5 0.75 1.0 1.5 2.0]
#endif

// 体积云的底部高度、厚度和主要形状尺度，单位均为方块。
#ifndef CLOUD_HEIGHT
#define CLOUD_HEIGHT 256.0 // [160.0 192.0 256.0 320.0 384.0]
#endif
#ifndef CLOUD_THICKNESS
#define CLOUD_THICKNESS 192.0 // [96.0 128.0 192.0 256.0 320.0]
#endif
#ifndef CLOUD_CELL_SIZE
#define CLOUD_CELL_SIZE 12.0 // [8.0 12.0 16.0 24.0]
#endif
#ifndef CLOUD_SPEED
#define CLOUD_SPEED 4.0 // [0.0 1.0 2.0 4.0 6.0 10.0]
#endif
#ifndef CLOUD_SIZE
#define CLOUD_SIZE 640.0 // [256.0 384.0 512.0 640.0 768.0 1024.0]
#endif
#ifndef CLOUD_SPACING
#define CLOUD_SPACING 320.0 // [256.0 288.0 320.0 352.0 384.0 432.0 480.0]
#endif
#ifndef CLOUD_DISTANCE
#define CLOUD_DISTANCE 6000.0
#endif
#ifndef CLOUD_OPACITY
#define CLOUD_OPACITY 0.65 // [0.0 0.2 0.35 0.5 0.65 0.8 0.95]
#endif
#ifndef CLOUD_NIGHT_BRIGHTNESS
#define CLOUD_NIGHT_BRIGHTNESS 1.0 // [0.0 0.5 1.0 1.5 2.0]
#endif

// 天空积分仅在低分辨率查找表运行；体积云质量改变视线和光照采样预算。
#ifndef SKY_SAMPLES
#define SKY_SAMPLES 16 // [16 24 32]
#endif
#ifndef SKY_HAZE
#define SKY_HAZE 1.0 // [0.5 1.0 1.5 2.0 3.0]
#endif
#ifndef SKY_EXPOSURE
#define SKY_EXPOSURE 1.0 // [0.6 0.8 1.0 1.2 1.5]
#endif
#ifndef CELESTIAL_SIZE
// 1.0 approximates vanilla's bright cores: sun 8.6 degrees, moon 5.7 degrees.
#define CELESTIAL_SIZE 0.5 // [0.5 0.75 1.0 1.25 1.5 2.0]
#endif
#ifndef CLOUD_QUALITY
#define CLOUD_QUALITY 0 // [0 1 2]
#endif
#ifndef CLOUD_COVERAGE
#define CLOUD_COVERAGE 0.35 // [0.0 0.35 0.45 0.50 0.58 0.70 0.85 1.0]
#endif
#ifndef CLOUD_DENSITY
#define CLOUD_DENSITY 0.75 // [0.5 0.75 1.0 1.5 2.0]
#endif
#ifndef CLOUD_BRIGHTNESS
#define CLOUD_BRIGHTNESS 1.0 // [0.6 0.8 1.0 1.2 1.5]
#endif
#ifndef CLOUD_SHADOW_STRENGTH
#define CLOUD_SHADOW_STRENGTH 0.65 // [0.0 0.35 0.65 0.85 1.0]
#endif

// 水面波浪：顶点动画 + 法线扰动。0 = 静止水面（省性能），1 = 开启。
#ifndef ENABLE_WATER_WAVES
#define ENABLE_WATER_WAVES 1 // [0 1]
#endif


// 无贴图水面保留暗青底色、少量群系染色、透明度与波浪；水的观感主要来自倒影。
#ifndef ENABLE_WATER_TEXTURE
#define ENABLE_WATER_TEXTURE 0 // [0 1]
#endif
#ifndef WATER_COLOR_LIGHTNESS
#define WATER_COLOR_LIGHTNESS 0.75 // [0.0 0.25 0.5 0.75 1.0]
#endif
#ifndef WATER_REFLECTION_BRIGHTNESS
#define WATER_REFLECTION_BRIGHTNESS 1.0 // [0.7 0.85 1.0 1.1 1.25 1.5]
#endif
#ifndef WATER_SPECULAR_STRENGTH
#define WATER_SPECULAR_STRENGTH 0.15 // [0.0 0.15 0.35 0.5 0.75 1.0]
#endif

// 体积场内部视口：0 四分之一，1 二分之一；场景本体仍按原分辨率渲染。
#ifndef VOLUMETRIC_RESOLUTION
#define VOLUMETRIC_RESOLUTION 0 // [0 1]
#endif

// 日光散射的固定距离区间数；减少区间节省阴影查询，低角度细光束会更粗。
#ifndef AIR_SCATTER_STEPS
#define AIR_SCATTER_STEPS 16 // [16 24 32 48]
#endif

// 近地面日光散射与丁达尔光束，0 关闭；低太阳高度与空间介质密度共同调节。
#ifndef AIR_SCATTER_STRENGTH
#define AIR_SCATTER_STRENGTH 0.65 // [0.0 0.35 0.65 1.0 1.5]
#endif

// 水色遮蔽随水内光程累积；浅水可见水底，深水以水色与倒影为主。
#ifndef WATER_SURFACE_OPACITY
#define WATER_SURFACE_OPACITY 0.12 // [0.0 0.02 0.04 0.06 0.08 0.12 0.2]
#endif
#ifndef WATER_TURBIDITY
#define WATER_TURBIDITY 0.035 // [0.0 0.015 0.035 0.06 0.1 0.16]
#endif
#ifndef WATER_ABSORPTION
#define WATER_ABSORPTION 0.45 // [0.0 0.25 0.45 0.7 1.0 1.5]
#endif
// 仅控制水下观察界面的轻微波动；水上水底图像保持固定坐标。
#ifndef WATER_REFRACTION_STRENGTH
#define WATER_REFRACTION_STRENGTH 1.0 // [0.0 0.5 1.0]
#endif

// 粗糙度控制高光宽度、倒影模糊与水下界面过滤，降低清晰镜面贡献。
#ifndef WATER_ROUGHNESS
#define WATER_ROUGHNESS 0.25 // [0.04 0.08 0.12 0.18 0.25 0.35]
#endif
#ifndef WATER_REFLECTION_STRENGTH
#define WATER_REFLECTION_STRENGTH 1.0 // [0.0 0.15 0.3 0.45 0.6 0.75 1.0]
#endif
// 倒影中的体积云：0 查 deferred 预建的云环境表，1 逐像素步进体积云（更细致、成本更高）。
#ifndef WATER_REFLECTION_CLOUDS
#define WATER_REFLECTION_CLOUDS 0 // [0 1]
#endif
// 屏幕空间倒影每条光线的最大步数；命中后另有 10 次二分细化，步数主要决定细小物体是否被跳过。
#ifndef WATER_REFLECTION_STEPS
#define WATER_REFLECTION_STEPS 16 // [16 24 32 48 64]
#endif
// 倒影光线沿阴影贴图步进的次数（另有 5 次二分细化），找出桥底、树冠下方、
// 树影里的山坡等相机看不到的遮挡；遮挡点明显更近时取代屏幕命中。
// 水面与材质倒影共用，0 关闭并退回天光衰减。
#ifndef REFLECTION_OCCLUSION_STEPS
#define REFLECTION_OCCLUSION_STEPS 6 // [0 6 10 16]
#endif

// 深水保留有限的近处辨识能力，不对远景解除光程衰减。
#ifndef UNDERWATER_MIN_VISIBILITY
#define UNDERWATER_MIN_VISIBILITY 0.12 // [0.0 0.06 0.12 0.18 0.24]
#endif
// 程序焦散只调制已有的日照辐射，0 关闭。
#ifndef WATER_CAUSTICS_STRENGTH
#define WATER_CAUSTICS_STRENGTH 0.0 // [0.0 0.35 0.65 1.0 1.5]
#endif
// 水下光柱的固定积分步数；与水底焦散质量独立。
#ifndef WATER_SHAFT_STEPS
#define WATER_SHAFT_STEPS 8 // [4 8 12 16 24]
#endif

// 半分辨率水下日光散射强度，0 关闭积分；默认使用八步。
#ifndef UNDERWATER_SHAFT_STRENGTH
#define UNDERWATER_SHAFT_STRENGTH 0.7 // [0.0 0.35 0.7 1.0 1.5]
#endif

// 水下统一光程衰减与散射，局部发光体保持独立照明。
#ifndef UNDERWATER_DENSITY
#define UNDERWATER_DENSITY 1.0 // [0.5 0.75 1.0 1.5 2.0]
#endif
#ifndef UNDERWATER_DEPTH_DIMMING
#define UNDERWATER_DEPTH_DIMMING 1.0 // [0.0 0.5 1.0 1.5 2.0]
#endif

// 薄植被的日月逆光透射强度，受阴影中的材质类别与厚度限制，0 关闭。
#ifndef FOLIAGE_TRANSLUCENCY
#define FOLIAGE_TRANSLUCENCY 0.4 // [0.0 0.2 0.4 0.6 0.8]
#endif

// 植被风摆：幅度单位为方块，地形和阴影阶段读取同一组设置。
#ifndef ENABLE_FOLIAGE_WIND
#define ENABLE_FOLIAGE_WIND 1 // [0 1]
#endif
#ifndef WIND_STRENGTH
#define WIND_STRENGTH 1.0 // [0.0 0.5 0.75 1.0 1.5 2.0]
#endif
#ifndef WIND_SPEED
#define WIND_SPEED 1.0 // [0.0 0.5 0.75 1.0 1.5 2.0]
#endif
#ifndef LEAF_SWAY_STRENGTH
#define LEAF_SWAY_STRENGTH 0.08 // [0.0 0.04 0.08 0.12 0.16]
#endif
#ifndef PLANT_SWAY_STRENGTH
#define PLANT_SWAY_STRENGTH 0.18 // [0.0 0.08 0.12 0.18 0.24 0.32]
#endif

/* ============================================================================
 * 六、后处理
 * ==========================================================================*/

// 色调映射曲线。0 = 不处理（直接截断，容易死白），
// 1 = ACES 近似（电影感，推荐），2 = Reinhard（简单，对比度低）。
#ifndef TONEMAP_MODE
#define TONEMAP_MODE 1 // [0 1 2]
#endif

// 曝光。整体亮度的乘数，在色调映射之前作用。
#ifndef EXPOSURE
#define EXPOSURE 1.0 // [0.6 0.8 1.0 1.2 1.5]
#endif

// 饱和度。1.0 = 不变，<1 变灰，>1 变艳。
#ifndef SATURATION
#define SATURATION 0.9 // [0.8 0.9 1.0 1.05 1.1 1.25]
#endif

// 对比度。以中灰 0.5 为中心拉伸。1.0 = 不变。
#ifndef CONTRAST
#define CONTRAST 1.0 // [0.9 0.95 1.0 1.05 1.1]
#endif

// 暗角强度。0 = 关闭，0.3 = 轻微。屏幕四角压暗。
#ifndef VIGNETTE
#define VIGNETTE 0.1 // [0.0 0.1 0.15 0.25 0.4]
#endif

// 泛光总开关。
#ifndef ENABLE_BLOOM
#define ENABLE_BLOOM 1 // [0 1]
#endif

// 泛光内部视口：0 半分辨率，1 全分辨率；只影响泛光，场景清晰度不变。
#ifndef BLOOM_RESOLUTION
#define BLOOM_RESOLUTION 0 // [0 1]
#endif

// 泛光亮度阈值；附近使用柔和过渡，减少亮部跨越阈值时的闪动。
#ifndef BLOOM_THRESHOLD
#define BLOOM_THRESHOLD 1.0 // [0.6 0.7 0.85 1.0 1.2]
#endif

// 泛光强度：叠加回原图时的倍率。
#ifndef BLOOM_STRENGTH
#define BLOOM_STRENGTH 0.25 // [0.0 0.1 0.25 0.4 0.6]
#endif

// 泛光半径倍率，以 1080p 为参考并限制采样间距。
#ifndef BLOOM_RADIUS
#define BLOOM_RADIUS 2.0 // [0.5 0.75 1.0 1.5 2.0]
#endif

// 受太阳遮挡与实际亮度控制的镜头光晕。
#ifndef ENABLE_LENS_FLARE
#define ENABLE_LENS_FLARE 1 // [0 1]
#endif
#ifndef LENS_FLARE_STRENGTH
#define LENS_FLARE_STRENGTH 0.18 // [0.0 0.1 0.18 0.3 0.5]
#endif

// 径向色差，强度为 1080p 画面角落的单侧像素偏移。
#ifndef ENABLE_CHROMATIC_ABERRATION
#define ENABLE_CHROMATIC_ABERRATION 1 // [0 1]
#endif
#ifndef CHROMATIC_ABERRATION_STRENGTH
#define CHROMATIC_ABERRATION_STRENGTH 0.6 // [0.0 0.35 0.6 1.0 1.5]
#endif

// 抖动（dither）。用噪声打散色带，避免天空等渐变区域出现条纹。
#ifndef ENABLE_DITHER
#define ENABLE_DITHER 1 // [0 1]
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
#define DEBUG_VIEW 0 // [0 1 2 3 4 5 6]
#endif



#define COLOURED_VOLUME_SIZE 32 // [32 48 64 96]
#define COLOURED_LIGHT_STEPS 1 // [1 2 3 4]
#define COLOURED_LIGHT_INTENSITY 1.0 // [0.0 0.5 0.75 1.0]
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
/*
const int colortex8Format = RGBA16F;
const int colortex5Format = R32UI;
const int colortex10Format = RGBA32F;
const int colortex11Format = RGBA8;
*/
const bool colortex8Clear = false;
const bool colortex5Clear = false;
const bool colortex10Clear = false;
const bool colortex11Clear = false;
#endif
#if GI_QUALITY > 0
/*
const int colortex12Format = RGBA16F;
*/
const bool colortex12Clear = false;
#endif
#endif  // SETTINGS_GLSL
