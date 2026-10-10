/* 全局渲染设置。集中定义加载器常量、缓冲格式和可调宏；各程序共享同一组默认值。
 * 游戏内选项由 shaders.properties 分组，用户选择由加载器保存。
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
// 使用手动 PCF，按表面入射角控制深度偏移。
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

// colortex5：水面八面体法线、天光可见度、线性深度，需保留法线精度。
const int colortex5Format = RGBA16F;
// colortex6：deferred 保存的、不含透明水体的 HDR 场景。
const int colortex6Format = RGBA16F;
// colortex7：水的局部散射辐射与薄层不透明度。
const int colortex7Format = RGBA16F;
*/

const bool colortex0Clear = true;
const vec4 colortex0ClearColor = vec4(0.0, 0.0, 0.0, 1.0);
const bool colortex1Clear = true;
const bool colortex2Clear = true;
const bool colortex3Clear = true;
const bool colortex4Clear = true;
const bool colortex5Clear = true;
const bool colortex6Clear = true;
const bool colortex7Clear = true;
const vec4 colortex7ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex5ClearColor = vec4(0.0, 0.0, 0.0, 0.0);


/* ============================================================================
 * 三、阴影设置
 * ==========================================================================*/

// 总开关。0 = 关闭阴影（同时省掉整个 shadow 渲染通道），1 = 开启。
#ifndef ENABLE_SHADOWS
#define ENABLE_SHADOWS 1 // [0 1]
#endif

// PCF 采样半径（单位：阴影贴图像素）。0 = 只采 1 个点（最硬），
// 1 = 3x3 共 9 个点，2 = 5x5 共 25 个点。越大越柔和也越慢。
#ifndef SHADOW_SOFTNESS
#define SHADOW_SOFTNESS 1 // [0 1 2]
#endif

// 阴影贴图的畸变强度。OptiFine 的阴影贴图是正交投影，覆盖整个 shadowDistance
// 范围，如果纹素均匀分布，近处会显得很糊。畸变把纹素向中心（近处）集中，
// 让脚下的阴影更清晰、远处的更糊 —— 这正好符合人眼的关注习惯。
//
//   0.0 = 不做畸变（纹素均匀分布）
//   0.9 = 常用值（推荐）
//   1.0 = 退化成全屏塌缩，【不要用】
#ifndef SHADOW_MAP_BIAS
#define SHADOW_MAP_BIAS 0.9 // [0.0 0.5 0.75 0.9 0.95]
#endif

// 深度偏移，用来消除"阴影痤疮"（shadow acne，表面出现条纹状自阴影）。
// 实际使用的偏移会随光线入射角变化，见 lib/shadow.glsl。
#ifndef SHADOW_BIAS
#define SHADOW_BIAS 0.00035 // [0.0001 0.0002 0.00035 0.0005 0.001]
#endif


/* ============================================================================
 * 四、光照强度
 * ==========================================================================*/

// 天空散射和暗处基础光的倍率，局部光单独控制。
#ifndef AMBIENT_STRENGTH
#define AMBIENT_STRENGTH 1.0 // [0.4 0.6 0.8 1.0 1.2]
#endif

// 日月直射分开调节，避免增强日光时同时把夜景照亮。
#ifndef SUNLIGHT_STRENGTH
#define SUNLIGHT_STRENGTH 1.0 // [0.0 0.4 0.6 0.8 1.0 1.2]
#endif
#ifndef MOONLIGHT_STRENGTH
#define MOONLIGHT_STRENGTH 0.03 // [0.0 0.009 0.018 0.03 0.05 0.075]
#endif
#ifndef NIGHT_AMBIENT_STRENGTH
#define NIGHT_AMBIENT_STRENGTH 0.08 // [0.0 0.02 0.04 0.06 0.08 0.12 0.16]
#endif
#ifndef NIGHT_EXPOSURE
#define NIGHT_EXPOSURE 1.6 // [1.0 1.25 1.6 2.0 2.5]
#endif

// 局部光在日照阴影之外累加；平滑采样作用于光照，不模糊材质纹理。
#ifndef BLOCK_LIGHT_STRENGTH
#define BLOCK_LIGHT_STRENGTH 2.0 // [0.0 0.5 1.0 1.5 2.0 2.5 3.0 4.0]
#endif
// 有界衰减的距离项，越大则光源外围越暗；原版零光照仍严格为零。
#ifndef BLOCK_LIGHT_FALLOFF
#define BLOCK_LIGHT_FALLOFF 6.0 // [2.0 4.0 6.0 9.0 12.0 18.0]
#endif
#ifndef SMOOTH_BLOCK_LIGHT
#define SMOOTH_BLOCK_LIGHT 1 // [0 1]
#endif

// 配套 Mod 提供独立点光阴影和多次漫反射体积；缺少数据时使用原版光照。
#ifndef ENABLE_COMPANION_LIGHTING
#define ENABLE_COMPANION_LIGHTING 1 // [0 1]
#endif
#ifndef ENABLE_LOCAL_SHADOWS
#define ENABLE_LOCAL_SHADOWS 1 // [0 1]
#endif
#ifndef LOCAL_LIGHT_COUNT
#define LOCAL_LIGHT_COUNT 32 // [8 16 32 64 128]
#endif
#ifndef LOCAL_LIGHT_RADIUS
#define LOCAL_LIGHT_RADIUS 16.0 // [8.0 12.0 16.0 20.0 24.0]
#endif
#ifndef LOCAL_SHADOW_RESOLUTION
#define LOCAL_SHADOW_RESOLUTION 128 // [32 64 128 192 256]
#endif
#ifndef LOCAL_SHADOW_UPDATES
#define LOCAL_SHADOW_UPDATES 2 // [1 2 4 8 16]
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
#define GI_BOUNCES 3 // [0 1 2 3 4 6]
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
#define GI_REFLECTANCE 0.75 // [0.35 0.5 0.65 0.75 0.85 0.9]
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
#define SKY_SAMPLES 24 // [16 24 32]
#endif
#ifndef SKY_HAZE
#define SKY_HAZE 1.0 // [0.5 1.0 1.5 2.0 3.0]
#endif
#ifndef SKY_EXPOSURE
#define SKY_EXPOSURE 1.0 // [0.6 0.8 1.0 1.2 1.5]
#endif
#ifndef CELESTIAL_SIZE
// 1.0 approximates vanilla's bright cores: sun 8.6 degrees, moon 5.7 degrees.
#define CELESTIAL_SIZE 1.0 // [0.5 0.75 1.0 1.25 1.5 2.0]
#endif
#ifndef CLOUD_QUALITY
#define CLOUD_QUALITY 1 // [0 1 2]
#endif
#ifndef CLOUD_COVERAGE
#define CLOUD_COVERAGE 0.50 // [0.0 0.35 0.45 0.50 0.58 0.70 0.85 1.0]
#endif
#ifndef CLOUD_DENSITY
#define CLOUD_DENSITY 1.0 // [0.5 0.75 1.0 1.5 2.0]
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


// 无贴图水面保留生物群系染色、透明度与波浪；浅色程度不会制造额外光照。
#ifndef ENABLE_WATER_TEXTURE
#define ENABLE_WATER_TEXTURE 0 // [0 1]
#endif
#ifndef WATER_COLOR_LIGHTNESS
#define WATER_COLOR_LIGHTNESS 0.5 // [0.0 0.25 0.5 0.75 1.0]
#endif
#ifndef WATER_REFLECTION_BRIGHTNESS
#define WATER_REFLECTION_BRIGHTNESS 1.1 // [0.7 0.85 1.0 1.1 1.25 1.5]
#endif
#ifndef WATER_SPECULAR_STRENGTH
#define WATER_SPECULAR_STRENGTH 0.35 // [0.0 0.15 0.35 0.5 0.75 1.0]
#endif

// 透射占主导；吸收按水内光程计算，浅水保留水底细节。
#ifndef WATER_SURFACE_OPACITY
#define WATER_SURFACE_OPACITY 0.06 // [0.0 0.02 0.04 0.06 0.08 0.12 0.2]
#endif
#ifndef WATER_TURBIDITY
#define WATER_TURBIDITY 0.035 // [0.0 0.015 0.035 0.06 0.1 0.16]
#endif
#ifndef WATER_ABSORPTION
#define WATER_ABSORPTION 0.45 // [0.0 0.25 0.45 0.7 1.0 1.5]
#endif
#ifndef WATER_REFRACTION_STRENGTH
#define WATER_REFRACTION_STRENGTH 1.0 // [0.0 0.5 1.0]
#endif

// 水面粗糙度同时控制直射高光宽度和倒影模糊范围。
#ifndef WATER_ROUGHNESS
#define WATER_ROUGHNESS 0.18 // [0.04 0.08 0.12 0.18 0.25 0.35]
#endif
#ifndef WATER_REFLECTION_STRENGTH
#define WATER_REFLECTION_STRENGTH 0.45 // [0.0 0.15 0.3 0.45 0.6 0.75 1.0]
#endif

// 深水保留有限的近处辨识能力，不对远景解除光程衰减。
#ifndef UNDERWATER_MIN_VISIBILITY
#define UNDERWATER_MIN_VISIBILITY 0.12 // [0.0 0.06 0.12 0.18 0.24]
#endif
#ifndef UNDERWATER_SURFACE_SOFTNESS
#define UNDERWATER_SURFACE_SOFTNESS 0.10 // [0.02 0.06 0.10 0.16 0.22]
#endif

// 水下统一光程衰减与散射，局部发光体保持独立照明。
#ifndef UNDERWATER_DENSITY
#define UNDERWATER_DENSITY 1.0 // [0.5 0.75 1.0 1.5 2.0]
#endif
#ifndef UNDERWATER_DEPTH_DIMMING
#define UNDERWATER_DEPTH_DIMMING 1.0 // [0.0 0.5 1.0 1.5 2.0]
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
#define SATURATION 1.05 // [0.8 0.9 1.0 1.05 1.1 1.25]
#endif

// 对比度。以中灰 0.5 为中心拉伸。1.0 = 不变。
#ifndef CONTRAST
#define CONTRAST 1.0 // [0.9 0.95 1.0 1.05 1.1]
#endif

// 暗角强度。0 = 关闭，0.3 = 轻微。屏幕四角压暗。
#ifndef VIGNETTE
#define VIGNETTE 0.15 // [0.0 0.1 0.15 0.25 0.4]
#endif

// 泛光总开关。
#ifndef ENABLE_BLOOM
#define ENABLE_BLOOM 1 // [0 1]
#endif

// 泛光亮度阈值：只有亮度超过这个值的像素才会发光溢出。
#ifndef BLOOM_THRESHOLD
#define BLOOM_THRESHOLD 0.85 // [0.6 0.7 0.85 1.0 1.2]
#endif

// 泛光强度：叠加回原图时的倍率。
#ifndef BLOOM_STRENGTH
#define BLOOM_STRENGTH 0.25 // [0.0 0.1 0.25 0.4 0.6]
#endif

// 泛光模糊半径（屏幕宽度的百分比）。
#ifndef BLOOM_RADIUS
#define BLOOM_RADIUS 1.0 // [0.5 0.75 1.0 1.5 2.0]
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


#endif  // SETTINGS_GLSL
