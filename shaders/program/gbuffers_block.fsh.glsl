#define SIMPLE_VARYING in
layout(location=0) out vec4 fullOut0;
layout(location=1) out vec4 fullOut1;
layout(location=2) out vec4 fullOut2;
layout(location=3) out vec4 fullOut3;
layout(location=4) out vec4 fullOut4;
#ifdef WORLD_GPU_BACKEND
/* RENDERTARGETS: 0,1,2,9 */
#else
/* RENDERTARGETS: 0,1,2,14,15 */
#endif

/*
 * 方块实体表面：床、箱子等模型采用与地形相同的环境光、局部光和日月阴影。
 * 此程序不负责选中框或挖掘裂纹，材质本身的白色不能作为自发光输出。
 */
/*
================================================================================
 lib/fragment_output.glsl —— gbuffers 片元输出（片元着色器专用）
================================================================================
 所有 gbuffers_* 片元着色器最后都要做同一件事：
   把结果写进 3 张颜色缓冲区（MRT，多渲染目标）。

 本项目使用的缓冲区分配（改动这里之前请先想清楚，因为后处理依赖它）：

   colortex0  场景颜色
              rgb = 已经算完光照和雾的 HDR 颜色
              a   = 透明度（给 _a 半透明程序用，其它时候为 1）

   colortex1  几何缓冲区 G-Buffer
              rg = 视图空间法线的八面体编码（完整球面）
              b  = 天空光等级
              a  = 材质标记（MAT_SOLID / MAT_WATER / ...）

   colortex2  光照缓冲区
              r = 方块光等级
              g = 天空光等级
              b = 阴影系数（1 = 受光，0 = 被遮挡）
              a = 材质类别与贴图亮度，由地形阶段补写

 为什么要拆成三张而不是塞进一张？
   1. 后处理需要的信息（法线、深度）和最终颜色是两种数据，
      混在一起就没法在被泛光污染之后还还原出干净的法线；
   2. 各阶段按寿命复用附件；colortex1 使用 16 位浮点，同时承载透明阶段
      的水面参数与雨层光学深度，colortex2 保留透明颜色的 HDR 范围。

 【只应被 .fsh 引用】—— 它写入了 gl_FragData，顶点着色器里不存在。
================================================================================
*/
#ifndef LIB_FRAGMENT_OUTPUT_GLSL
#define LIB_FRAGMENT_OUTPUT_GLSL

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

/*
 * color_space.glsl —— 游戏颜色输入的显示空间转换。
 *
 * 贴图、顶点色、天空色和雾色由游戏按显示颜色提供。它们参与光照、
 * 雾和泛光之前，先转到线性空间；final.fsh 最后再编码回显示空间。
 * 这里使用与 lib/tonemap.glsl 相配的 gamma 2.2 近似。
 */
#ifndef LIB_COLOR_SPACE_GLSL
#define LIB_COLOR_SPACE_GLSL

vec3 toLinearSpace(vec3 color) {
    return pow(max(color, vec3(0.0)), vec3(2.2));
}

#endif

/* 表面光照。分别计算日月直射、天空环境光与局部方块光；AO 作用于间接项。
 * 配套数据就绪时接入独立点光阴影和体素 GI，其他情况使用原版光照场。
 */
#ifndef LIB_LIGHTING_GLSL
#define LIB_LIGHTING_GLSL





/*
 * Minecraft 光照贴图的连续采样与光源分离。
 * 在相邻等级的纹素中心手动插值，避免加载器的最近邻采样造成亮度台阶。
 * 方块光从无天光的行中提取，保留原版传播和遮挡，同时避免白天天光饱和将火把光压掉。
 */
#ifndef LIB_LIGHTMAP_GLSL
#define LIB_LIGHTMAP_GLSL




uniform sampler2D lightmap;

vec2 prepareLightmapCoord(vec2 coordinate) {
    return clamp(coordinate, vec2(0.03125), vec2(0.96875));
}

// 光照坐标的端点是半个纹素；移除这个偏移后得到连续的 0–15 级亮度。
float lightmapLevel(float coordinate) {
    return clamp((coordinate - 0.03125) / 0.9375, 0.0, 1.0);
}

vec3 lightmapTexel(vec2 pixel) {
    return toLinearSpace(texture(lightmap, (pixel + 0.5) / 16.0).rgb);
}

vec3 sampleLightmapColor(vec2 coordinate) {
#if SMOOTH_BLOCK_LIGHT == 0
    vec2 pixel = min(floor(prepareLightmapCoord(coordinate) * 16.0), vec2(15.0));
    return lightmapTexel(pixel);
#else
    vec2 pixel = prepareLightmapCoord(coordinate) * 16.0 - 0.5;
    vec2 lower = floor(pixel);
    vec2 upper = min(lower + 1.0, vec2(15.0));
    vec2 weight = fract(pixel);
    vec3 bottom = mix(lightmapTexel(lower), lightmapTexel(vec2(upper.x, lower.y)), weight.x);
    vec3 top = mix(lightmapTexel(vec2(lower.x, upper.y)), lightmapTexel(upper), weight.x);
    return mix(bottom, top, weight.y);
#endif
}

// 暗处的基础亮度只计一次；它由游戏的亮度/夜视设置决定。
vec3 lightmapDarkFloor() {
    return lightmapTexel(vec2(0.0));
}

// 将原版传播等级当作可见度与有效距离的代理，使用连续的有界衰减。
// 光照贴图只提供传播等级，暖光颜色与近场能量单独校准，不重复计入日月直射。
// 这里没有光源坐标，距离是传播场近似；墙体遮挡仍由游戏计算。
// 已知光源发光等级时，路径长度为 emission - level，窗口覆盖光源自身的射程；
// near 是光源所在格的等效距离（方块），限制近场峰值。
float emitterLightAttenuation(float level, float emission, float near) {
    float distanceFraction = 1.0 - clamp(level / max(emission, 1.0), 0.0, 1.0);
    float distanceSquared = distanceFraction * distanceFraction;
    float cutoff = 1.0 - distanceSquared * distanceSquared;
    // 平方窗让零光照处的值和斜率均归零。
    float distanceBlocks = near + distanceFraction * emission;
    return cutoff * cutoff
         / (1.0 + (BLOCK_LIGHT_FALLOFF / 6.0) * distanceBlocks * distanceBlocks);
}

// 光照贴图不含光源等级，按 15 级光源解释传播等级，一格源半径。
// 火把（14 级）所在格因此按两格距离计算，这是整套方块光亮度的校准基准。
float blockLightAttenuation(float level) {
    return emitterLightAttenuation(clamp(level, 0.0, 1.0) * 15.0, 15.0, 1.0);
}

vec3 blockLightRadiance(vec2 coordinate) {
    float level = lightmapLevel(coordinate.x);
#if SMOOTH_BLOCK_LIGHT == 0
    level = floor(level * 15.0 + 0.5) / 15.0;
#endif
    float attenuation = blockLightAttenuation(level);
    // 原版峰值接近白色，不能作为火把的线性辐射色；与 Mod 的暖光校准一致。
    vec3 tint = toLinearSpace(vec3(1.0, 0.65, 0.32));
    // 近场峰值为 2，与 Mod 的点光源能量尺度接近；外围由方块距离衰减。
    return tint * (4.0 * attenuation) * BLOCK_LIGHT_STRENGTH;
}

vec3 skyLightRadiance(vec2 coordinate) {
    vec3 sky = sampleLightmapColor(vec2(0.03125, coordinate.y));
    return max(sky - lightmapDarkFloor(), vec3(0.0));
}

#endif

/*
 * Spherical atmosphere integration in kilometres. Rayleigh, aerosol scattering
 * and ozone absorption share one density model. A small sky-view lookup is
 * rebuilt before transparent geometry; higher scattering orders are approximated
 * by a modest isotropic source. No compute shader or high-dimensional LUT is used.
 */
#ifndef LIB_ATMOSPHERE_GLSL
#define LIB_ATMOSPHERE_GLSL




/* Dimension-local environment radiance. Nether fog follows the current biome;
 * the End has a fixed cool hemispherical fill and a continuous procedural void.
 * These are artistic ambient sources, independent of solar time and block light.
 */
#ifndef LIB_DIMENSION_GLSL
#define LIB_DIMENSION_GLSL




/* Small analytic fields shared by sky emission and near-ground media. No
 * gtexture sampler or screen derivative is needed; periodic fields keep terrain
 * patterns stable when the companion rebases its camera-centred grid.
 */
#ifndef LIB_ATMOSPHERE_NOISE_GLSL
#define LIB_ATMOSPHERE_NOISE_GLSL
float atmosphereHash(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

float atmosphereNoise2(vec2 p, float period) {
    vec2 cell = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    vec2 a = mod(cell, period);
    vec2 b = mod(cell + 1.0, period);
    float lower = mix(atmosphereHash(vec3(a, 0.0)), atmosphereHash(vec3(b.x, a.y, 0.0)), f.x);
    float upper = mix(atmosphereHash(vec3(a.x, b.y, 0.0)), atmosphereHash(vec3(b, 0.0)), f.x);
    return mix(lower, upper, f.y);
}

float atmosphereNoise3(vec3 p) {
    vec3 cell = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(atmosphereHash(cell), atmosphereHash(cell + vec3(1.0, 0.0, 0.0)), f.x);
    float b = mix(atmosphereHash(cell + vec3(0.0, 1.0, 0.0)), atmosphereHash(cell + vec3(1.0, 1.0, 0.0)), f.x);
    float c = mix(atmosphereHash(cell + vec3(0.0, 0.0, 1.0)), atmosphereHash(cell + vec3(1.0, 0.0, 1.0)), f.x);
    float d = mix(atmosphereHash(cell + vec3(0.0, 1.0, 1.0)), atmosphereHash(cell + vec3(1.0, 1.0, 1.0)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}
#endif


vec3 dimensionFogColor() {
#if SIMPLE_DIMENSION == -1
    vec3 biome = max(toLinearSpace(fogColor), vec3(0.018, 0.006, 0.004));
    float low = 1.0 - smoothstep(28.0, 85.0, cameraPosition.y);
    float warmBiome = smoothstep(-0.02, 0.08, biome.r - biome.b);
    return mix(biome, biome * vec3(1.12, 0.92, 0.82) + vec3(0.020, 0.003, 0.001),
               NETHER_ATMOSPHERE * low * mix(0.08, 0.42, warmBiome));
#elif SIMPLE_DIMENSION == 1
    return mix(vec3(0.022, 0.016, 0.039), vec3(0.021, 0.020, 0.047), END_ATMOSPHERE * 0.60);
#else
    return toLinearSpace(fogColor);
#endif
}

vec3 dimensionAmbient(vec3 normalWorld) {
#if SIMPLE_DIMENSION == -1
    vec3 biome = dimensionFogColor();
    vec3 tint = mix(vec3(0.82, 0.64, 0.51), biome / max(luma(biome), 0.02), 0.18);
    tint = mix(tint, tint * vec3(1.05, 0.97, 0.92), NETHER_ATMOSPHERE * 0.45);
    return tint * NETHER_AMBIENT * (0.70 + 0.30 * max(-normalWorld.y, 0.0));
#elif SIMPLE_DIMENSION == 1
    return mix(vec3(0.46, 0.38, 0.62), vec3(0.75, 0.80, 1.0),
               normalWorld.y * 0.5 + 0.5) * END_AMBIENT
         + vec3(0.010, 0.020, 0.035) * END_ATMOSPHERE * max(normalWorld.y, 0.0);
#else
    return vec3(0.0);
#endif
}

vec3 dimensionBackground(vec3 direction) {
#if SIMPLE_DIMENSION == 1
    // Direction-only fields keep the void stable under camera translation and
    // avoid a longitude seam, polar singularity or a second apparent sun.
    float band = sin(direction.x * 4.0 + direction.y * 3.0)
               * sin(direction.z * 5.0 - direction.y * 2.0);
    float wisps = pow(clamp(band * 0.5 + 0.5, 0.0, 1.0), 4.0);
    vec3 p = direction * 540.0;
    float seed = hash13(floor(p));
    float star = (1.0 - smoothstep(0.08, 0.32, length(fract(p) - 0.5)))
               * step(0.9985, seed);
    vec3 base = dimensionFogColor() * (0.65 + wisps * 0.65)
              + vec3(0.30, 0.36, 0.50) * star * 0.35 * (1.0 - smoothstep(0.0, 0.1, END_ATMOSPHERE));
    float phase = frameTimeCounter * TAU / 3600.0;
    vec3 drift = vec3(sin(phase * 2.0), 0.0, cos(phase * 2.0)) * 0.20;
    float warp = atmosphereNoise3(direction * 3.0 + drift);
    float plane = dot(direction, normalize(vec3(0.35, 0.82, 0.24))) + (warp - 0.5) * 0.35;
    float nebula = exp(-plane * plane * 32.0);
    float detail = atmosphereNoise3(direction * 11.0 + drift);
    vec3 palette = mix(vec3(0.065, 0.018, 0.090), vec3(0.018, 0.075, 0.10), detail);
    return base + palette * nebula * (0.20 + detail * detail) * END_ATMOSPHERE;
#else
    return dimensionFogColor() * mix(0.85, 1.05, direction.y * 0.5 + 0.5);
#endif
}
#endif

/* Optically thin emissive curtains in a spherical upper-atmosphere shell.
 * Evaluated in the small sky LUT, shared by sky, water and opaque reflections.
 * The emission follows a stylised green oxygen band with purple/red fringes;
 * it has no screen-space derivatives, longitude seam or horizon division.
 */
#ifndef LIB_AURORA_GLSL
#define LIB_AURORA_GLSL





float auroraShellDistance(vec3 origin, vec3 direction, float radius) {
    float b = dot(origin, direction);
    float c = dot(origin, origin) - radius * radius;
    return max(-b + sqrt(max(b * b - c, 0.0)), 0.0);
}

vec3 auroraRadiance(vec3 direction) {
#if SIMPLE_DIMENSION != 0
    return vec3(0.0);
#else
    vec3 sun = safeNormalize(mat3(gbufferModelViewInverse) * sunPosition, vec3(0.0, 1.0, 0.0));
    float night = 1.0 - smoothstep(-0.22, -0.07, sun.y);
    if (AURORA_STRENGTH <= 0.0 || night <= 0.001 || direction.y <= 0.015) {
        return vec3(0.0);
    }
    const float radius = 6371.0;
    vec3 origin = vec3(0.0, radius + clamp(cameraPosition.y * 0.001, 0.05, 4.0), 0.0);
    float start = auroraShellDistance(origin, direction, radius + 90.0);
    float end = auroraShellDistance(origin, direction, radius + 150.0);
    float phase = frameTimeCounter * TAU / 3600.0 * float(AURORA_SPEED);
    vec2 drift = vec2(sin(phase * 3.0), cos(phase * 3.0)) * 0.8;
    vec3 radiance = vec3(0.0);
    for (int index = 0; index < AURORA_STEPS; index++) {
        float t = (float(index) + 0.5) / float(AURORA_STEPS);
        vec3 position = origin + direction * mix(start, end, t);
        float height = clamp((length(position) - radius - 90.0) / 60.0, 0.0, 1.0);
        vec2 p = position.xz * 0.012 + drift * 0.25;
        float warp = atmosphereNoise2(vec2(p.x * 0.45, 11.5), 128.0) - 0.5;
        float curve = -2.10 + sin(p.x * 0.85 + phase * 3.0) * 0.45 + warp * 0.32;
        float farCurve = -4.60 + sin(p.x * 0.60 - phase * 2.0 + 1.7) * 0.65;
        float ribbon = p.y - curve;
        float farRibbon = p.y - farCurve;
        float baseWidth = mix(0.11, 0.18, height);
        float angularPixel = TAU / max(floor(viewWidth * 0.125), 1.0);
        float footprint = length(position - origin) * 0.012 * angularPixel / 3.464;
        float width = sqrt(baseWidth * baseWidth + footprint * footprint);
        float curtain = exp(-ribbon * ribbon / (width * width));
        curtain += 0.55 * exp(-farRibbon * farRibbon / (width * width * 1.5));
        float strands = atmosphereNoise2(vec2(p.x * 9.0 + drift.x, 7.5), 128.0);
        float vertical = smoothstep(0.0, 0.07, height) * exp(-height * 2.4);
        float density = curtain * vertical * (0.35 + 0.65 * strands * strands) * baseWidth / width;
        vec3 colour = mix(vec3(0.06, 0.90, 0.32), vec3(0.55, 0.045, 0.16), smoothstep(0.40, 1.0, height));
        colour += vec3(0.22, 0.045, 0.30) * exp(-pow((height - 0.10) / 0.10, 2.0));
        radiance += colour * density / float(AURORA_STEPS);
    }
    float moon = 0.5 + 0.5 * cos(float(moonPhase) * PI * 0.25);
    float north = mix(0.25, 1.0, smoothstep(-0.15, 0.65, -direction.z));
    float activity = 0.75 + 0.25 * sin(float(worldDay) * 1.618 + 0.7);
    return radiance * 2.0 * AURORA_STRENGTH * night * north * activity
         * (1.0 - rainStrength * 0.95) * mix(1.0, 0.65, moon)
         * smoothstep(0.015, 0.12, direction.y);
#endif
}
#endif

/* 连续天气响应。天空、日照和环境光共用雨量，地表积水另用滞后的湿度。
 * 主世界以外保留各维度原有环境，雨停后的地表不会立即恢复干燥。
 */
#ifndef LIB_WEATHER_GLSL
#define LIB_WEATHER_GLSL





uniform float rainBiome;

float weatherRainAmount() {
#if SIMPLE_DIMENSION != 0
    return 0.0;
#else
    return smoothstep(0.0, 1.0, rainStrength);
#endif
}

vec3 weatherSkyRadiance(vec3 clearSky) {
    float rain = weatherRainAmount();
    float brightness = luma(clearSky);
    vec3 overcast = vec3(0.92, 0.96, 1.0) * brightness * 0.62;
    return mix(clearSky, overcast, rain * 0.96);
}

float weatherGroundWetness() {
#if SIMPLE_DIMENSION != 0
    return 0.0;
#else
    return clamp(wetness, 0.0, 1.0) * clamp(rainBiome, 0.0, 1.0);
#endif
}

// Rain streaks and impact particles share one display-space blue-grey palette.
vec3 rainDropAlbedo() {
#if ENABLE_REALISTIC_RAIN == 1
    return vec3(0.48, 0.56, 0.65);
#else
    return vec3(0.09, 0.13, 0.19);
#endif
}

// Two spare water-parameter channels accumulate rain optical depth and its
// intensity moment. Constant-colour layers compose exactly; SIMPLE_VARYING light uses
// an optical-depth-weighted mean without requiring a ninth macOS attachment.
vec4 rainOverlayMoments(float intensity, float alpha) {
    float opticalDepth = -log(max(1.0 - clamp(alpha, 0.0, 0.999), 0.001));
    return vec4(0.0, 0.0, opticalDepth * intensity, opticalDepth);
}

vec3 applyRainOverlay(vec3 background, vec4 parameters, bool waterPresent) {
    float opticalDepth = max(parameters.a - (waterPresent ? 1.0 : 0.0), 0.0);
    if (opticalDepth <= 0.00001) {
        return background;
    }
    float transmission = exp(-opticalDepth);
    vec3 tint = toLinearSpace(rainDropAlbedo());
    float intensity = parameters.b / opticalDepth;
    return background * transmission + tint * intensity * (1.0 - transmission);
}

// 原版水花的蓝色贴图及其低红色青色变体共用雨丝配色。
// 仅在降雨群系、相机未入水时调整；中性色、暖色及明亮青色不受影响。
float rainParticleWeight(vec3 texel) {
    if (isEyeInWater != 0 || weatherRainAmount() <= 0.001 || rainBiome <= 0.001) {
        return 0.0;
    }
    float blue = smoothstep(0.18, 0.32, texel.b - max(texel.r, texel.g));
    float cyan = (1.0 - smoothstep(0.04, 0.12, texel.r))
               * smoothstep(0.45, 0.65, min(texel.g, texel.b))
               * (1.0 - smoothstep(0.04, 0.10, abs(texel.g - texel.b)));
    return max(blue, cyan) * rainBiome;
}

#endif


const float SKY_PLANET_RADIUS = 6371.0;
const float SKY_ATMOSPHERE_RADIUS = 6451.0;
const vec3 SKY_RAYLEIGH = vec3(0.005802, 0.013558, 0.033100);
const vec3 SKY_OZONE = vec3(0.000650, 0.001881, 0.000085);

vec3 skySunDirection() {
    return safeNormalize(mat3(gbufferModelViewInverse) * sunPosition, vec3(0.0, 1.0, 0.0));
}

vec3 skyMoonDirection() {
    return safeNormalize(mat3(gbufferModelViewInverse) * moonPosition, vec3(0.0, 1.0, 0.0));
}

float skyDaylight() {
    return smoothstep(-0.12, 0.16, skySunDirection().y);
}

// Twilight spans both sides of the geometric horizon; the direct solar source
// still vanishes below it. These terms approximate diffuse multiple scattering.
float atmosphereTwilight() {
#if SIMPLE_DIMENSION != 0
    return 0.0;
#else
    float height = skySunDirection().y;
    return exp(-pow((height + 0.025) / 0.11, 2.0)) * TWILIGHT_STRENGTH
         * (1.0 - rainStrength * 0.80);
#endif
}

vec3 twilightIrradiance(vec3 normalWorld) {
    vec3 sun = skySunDirection();
    vec3 horizontal = safeNormalize(vec3(sun.x, 0.0, sun.z), vec3(1.0, 0.0, 0.0));
    float warm = clamp(0.4 + 0.45 * dot(normalWorld, horizontal) + 0.15 * normalWorld.y, 0.0, 1.0);
    return mix(vec3(0.035, 0.050, 0.10), vec3(0.20, 0.060, 0.020), warm) * atmosphereTwilight();
}

vec3 twilightSkyRadiance(vec3 direction) {
    vec3 sun = skySunDirection();
    vec3 horizontal = safeNormalize(vec3(sun.x, 0.0, sun.z), vec3(1.0, 0.0, 0.0));
    float facing = dot(direction, horizontal);
    float horizon = exp(-pow((direction.y - 0.025) / 0.18, 2.0));
    float solar = pow(max(facing, 0.0), 2.0) * horizon;
    float opposite = pow(max(-facing, 0.0), 2.0)
                   * exp(-pow((direction.y - 0.12) / 0.10, 2.0));
    return (vec3(0.22, 0.052, 0.016) * solar + vec3(0.045, 0.018, 0.035) * opposite)
         * atmosphereTwilight() * smoothstep(-0.04, 0.02, direction.y);
}

float lunarIlluminatedFraction() {
    return 0.5 + 0.5 * cos(float(moonPhase) * PI * 0.25);
}

vec3 atmosphereDensity(float altitude) {
    altitude = max(altitude, 0.0);
    float ozone = max(0.0, 1.0 - abs(altitude - 25.0) / 15.0);
    return vec3(exp(-altitude / 8.0), exp(-altitude / 1.2), ozone);
}

float atmosphereAerosol() {
    return SKY_HAZE * mix(1.0, 3.0, rainStrength);
}

vec3 atmosphereExtinction(vec3 columns) {
    return SKY_RAYLEIGH * columns.x
         + vec3(0.004440 * atmosphereAerosol()) * columns.y
         + SKY_OZONE * columns.z;
}

// Kasten-style optical air mass is inexpensive enough for geometry and discs.
vec3 atmosphereDirectTransmittance(float elevation) {
    float mu = max(elevation, 0.0);
    float zenith = acos(clamp(mu, 0.0, 1.0)) * 180.0 / PI;
    float airMass = 1.0 / (mu + 0.50572 * pow(max(96.07995 - zenith, 0.01), -1.6364));
    return exp(-atmosphereExtinction(vec3(8.0, 1.2, 15.0) * airMass));
}

// Stable roots also allow twilight scattering above the ground shadow.
float atmosphereExitDistance(vec3 origin, vec3 ray, float radius) {
    float b = dot(origin, ray);
    float c = dot(origin, origin) - radius * radius;
    return max(-b + sqrt(max(b * b - c, 0.0)), 0.0);
}

bool atmosphereGroundBlocks(vec3 origin, vec3 ray) {
    float b = dot(origin, ray);
    float c = dot(origin, origin) - SKY_PLANET_RADIUS * SKY_PLANET_RADIUS;
    return b < 0.0 && b * b - c > 0.0;
}

// Six non-uniform samples concentrate work in the dense lower atmosphere.
vec3 atmosphereLightTransmission(vec3 origin, vec3 lightDirection) {
    if (atmosphereGroundBlocks(origin, lightDirection)) {
        return vec3(0.0);
    }
    float distance = atmosphereExitDistance(origin, lightDirection, SKY_ATMOSPHERE_RADIUS);
    vec3 columns = vec3(0.0);
    float previous = 0.0;
    for (int stepIndex = 0; stepIndex < 6; stepIndex++) {
        float u = float(stepIndex + 1) / 6.0;
        float next = u * u * distance;
        vec3 position = origin + lightDirection * (previous + next) * 0.5;
        columns += atmosphereDensity(length(position) - SKY_PLANET_RADIUS) * (next - previous);
        previous = next;
    }
    return exp(-atmosphereExtinction(columns));
}

float atmosphereMiePhase(float cosine) {
    const float g = 0.76;
    return (1.0 - g * g) / (4.0 * PI * pow(max(1.0 + g * g - 2.0 * g * cosine, 0.01), 1.5));
}

// This is evaluated only in the small sky-view pass, not per scene pixel.
vec3 integrateAtmosphere(vec3 direction) {
#if SIMPLE_DIMENSION != 0
    return dimensionBackground(direction);
#endif
    vec3 ray = direction;
    if (ray.y < 0.003) {
        // 下半球使用地平线延续；先归一化水平方向，不能把接近零的
        // xz 与固定 y 相除，否则正下方会突然变成天顶方向。
        vec2 horizontal = length(ray.xz) > 0.00001
            ? normalize(ray.xz) : vec2(1.0, 0.0);
        ray = vec3(horizontal.x, 0.003, horizontal.y);
    }
    ray = normalize(ray);
    float altitude = clamp(cameraPosition.y * 0.001, 0.05, 4.0);
    vec3 origin = vec3(0.0, SKY_PLANET_RADIUS + altitude, 0.0);
    float distance = atmosphereExitDistance(origin, ray, SKY_ATMOSPHERE_RADIUS);
    vec3 sun = skySunDirection();
    vec3 moon = skyMoonDirection();
    float sunCosine = dot(ray, sun);
    float moonCosine = dot(ray, moon);
    float sunRayleighPhase = 3.0 * (1.0 + sunCosine * sunCosine) / (16.0 * PI);
    float moonRayleighPhase = 3.0 * (1.0 + moonCosine * moonCosine) / (16.0 * PI);
    float sunMiePhase = atmosphereMiePhase(sunCosine);
    float moonMiePhase = atmosphereMiePhase(moonCosine);
    float moonEnergy = MOONLIGHT_STRENGTH * (0.08 + 0.92 * lunarIlluminatedFraction()) * 0.25;
    vec3 transmittance = vec3(1.0);
    vec3 radiance = vec3(0.0);
    float previous = 0.0;
    for (int stepIndex = 0; stepIndex < SKY_SAMPLES; stepIndex++) {
        float u = float(stepIndex + 1) / float(SKY_SAMPLES);
        float next = u * u * distance;
        float stepLength = next - previous;
        vec3 position = origin + ray * (previous + next) * 0.5;
        vec3 density = atmosphereDensity(length(position) - SKY_PLANET_RADIUS);
        vec3 extinction = atmosphereExtinction(density);
        vec3 rayleigh = SKY_RAYLEIGH * density.x;
        vec3 mie = vec3(0.003996 * atmosphereAerosol() * density.y);
        vec3 sunlight = atmosphereLightTransmission(position, sun);
        vec3 moonlight = atmosphereLightTransmission(position, moon);
        vec3 source = (rayleigh * (sunRayleighPhase + 0.018) + mie * sunMiePhase) * sunlight;
        source += (rayleigh * (moonRayleighPhase + 0.012) + mie * moonMiePhase)
                * moonlight * moonEnergy;
        vec3 segmentTransmission = exp(-extinction * stepLength);
        radiance += transmittance * source * (1.0 - segmentTransmission) / max(extinction, vec3(0.000001));
        transmittance *= segmentTransmission;
        previous = next;
    }
    radiance *= 18.0 * SKY_EXPOSURE;
    // 弱夜间散射基底与地表天空环境光共用强度，远处雾保持同一冷色背景。
    radiance += vec3(0.03, 0.06, 0.12) * NIGHT_AMBIENT_STRENGTH * (1.0 - skyDaylight());
    // The lower hemisphere is the horizon continuation, not a second ground mesh.
    vec3 clearSky = radiance * mix(0.75, 1.0, smoothstep(-0.5, 0.0, direction.y))
                  + twilightSkyRadiance(direction) + auroraRadiance(direction);
    return weatherSkyRadiance(clearSky);
}

#endif

/*
 * Continuous cloud density and inexpensive projected cloud shadows.
 * The tiled 64-cubed periodic field is baked by tools/build_sky_assets.py.
 * Weather changes cloud coverage and vertical profile; three Worley bands erode
 * the boundary without introducing a block lattice or per-frame shape popping.
 * A finite, camera-centred weather field fades into the horizon before its
 * boundary. View rays, environment lookups and projected shadows share it.
 */
#ifndef LIB_CLOUD_DENSITY_GLSL
#define LIB_CLOUD_DENSITY_GLSL




/* Shared sampler for the packed periodic cloud volume and lunar albedo. */
#ifndef LIB_SKY_NOISE_GLSL
#define LIB_SKY_NOISE_GLSL
uniform sampler2D noisetex;
#endif


float cloudCellHash(vec2 cell) {
    vec3 value = fract(vec3(cell.x, cell.y, cell.x) * 0.1031);
    value += dot(value, value.yzx + 33.33);
    return fract((value.x + value.y) * value.z);
}

float cloudWeatherNoise(vec2 coordinate) {
    vec2 cell = floor(coordinate);
    vec2 weight = fract(coordinate);
    weight = weight * weight * (3.0 - 2.0 * weight);
    float lower = mix(cloudCellHash(cell), cloudCellHash(cell + vec2(1.0, 0.0)), weight.x);
    float upper = mix(cloudCellHash(cell + vec2(0.0, 1.0)), cloudCellHash(cell + vec2(1.0)), weight.x);
    return mix(lower, upper, weight.y);
}

vec4 cloudVolumeNoise(vec3 coordinate) {
    vec3 p = fract(coordinate) * 64.0;
    float slice = floor(p.z);
    float nextSlice = mod(slice + 1.0, 64.0);
    vec2 first = vec2(mod(slice, 8.0), floor(slice / 8.0)) * 66.0;
    vec2 second = vec2(mod(nextSlice, 8.0), floor(nextSlice / 8.0)) * 66.0;
    vec2 inside = p.xy + 1.5;
    vec4 lower = texture(noisetex, (first + inside) / 1024.0);
    vec4 upper = texture(noisetex, (second + inside) / 1024.0);
    return mix(lower, upper, fract(p.z));
}

vec2 cloudWindOffset() {
    return frameTimeCounter * CLOUD_SPEED * vec2(1.0, 0.21);
}

// Keep several cloud groups visible even at short terrain draw distances.
// The loader's far plane follows render distance; simulation distance does not
// describe visibility. CLOUD_DISTANCE remains the hard upper work budget.
float cloudRenderDistance() {
    float minimumDistance = max(1536.0, CLOUD_SIZE * 3.0);
    return min(CLOUD_DISTANCE, max(far * 8.0, minimumDistance));
}

// Removing density as well as contrast prevents a long grazing ray through the
// flat layer from building an opaque wall. Squared distance avoids a square root
// per noise/light sample; the fade is continuous when the camera moves.
float cloudHorizonVisibility(vec3 world) {
    vec2 offset = world.xz - cameraPosition.xz;
    float radius = cloudRenderDistance();
    float distanceSquared = dot(offset, offset);
    float visibility = 1.0 - smoothstep(radius * radius * 0.25,
                                       radius * radius, distanceSquared);
    return visibility * visibility;
}

// Broad-phase bounds include every possible local base and cloud thickness.
// Both view rays and shadow rays must include these bounds to avoid clipping
// elevated clouds or prematurely rejecting the lower cloud groups.
vec2 cloudAltitudeBounds() {
    return vec2(CLOUD_HEIGHT - CLOUD_THICKNESS * 0.65,
                CLOUD_HEIGHT + CLOUD_THICKNESS * 1.90);
}

// Regional and cloud-group variations move with the weather field. Thickness
// varies independently, so the layer has uneven bottoms as well as uneven tops.
vec2 cloudColumnBounds(vec2 position, float type) {
    float groupHeight = cloudWeatherNoise(position / (CLOUD_SIZE * 0.60)
                                          + vec2(127.0, 59.0));
    float heightField = mix(type, groupHeight, 0.40);
    float offset = (heightField * 2.0 - 1.0) * CLOUD_THICKNESS * 0.65;
    float bottom = CLOUD_HEIGHT + offset;
    float thickness = CLOUD_THICKNESS * mix(0.75, 1.25, type);
    return vec2(bottom, bottom + thickness);
}

// Return local relative height with density; cloud lighting can reuse it without
// repeating the weather samples or treating every cloud as equally elevated.
float cloudDensityWithHeight(vec3 world, bool erosion, out float height) {
    height = 0.0;
    vec2 altitude = cloudAltitudeBounds();
    if (world.y <= altitude.x || world.y >= altitude.y
        || CLOUD_COVERAGE <= 0.0 || CLOUD_OPACITY <= 0.0) {
        return 0.0;
    }
    float horizon = cloudHorizonVisibility(world);
    if (horizon <= 0.0001) {
        return 0.0;
    }
    vec2 horizontal = world.xz - cloudWindOffset();
    float type = cloudWeatherNoise(horizontal / (CLOUD_SIZE * 4.0) + 43.0);
    vec2 column = cloudColumnBounds(horizontal, type);
    height = (world.y - column.x) / (column.y - column.x);
    if (height <= 0.0 || height >= 1.0) {
        return 0.0;
    }
    vec3 position = vec3(horizontal.x, world.y - column.x, horizontal.y);
    float weather = cloudWeatherNoise(position.xz / (CLOUD_SIZE * 2.5)) * 0.65
                  + cloudWeatherNoise(position.xz / (CLOUD_SIZE * 0.85) + 19.0) * 0.35;
    float coverage = clamp(CLOUD_COVERAGE + (weather - 0.5) * 0.36 + rainStrength * 0.22, 0.02, 0.96);
    float profile = smoothstep(0.0, 0.08, height)
                  * (1.0 - smoothstep(mix(0.42, 0.70, type), 1.0, height));
    vec4 noise = cloudVolumeNoise(position / CLOUD_SIZE);
    float shape = clamp((noise.r - (1.0 - coverage)) / 0.20, 0.0, 1.0) * profile;
    if (erosion && shape > 0.0) {
        float detail = noise.g * 0.5 + noise.b * 0.3 + noise.a * 0.2;
        shape = max(shape - (1.0 - detail) * 0.18 * (1.0 - shape), 0.0);
    }
    return shape * CLOUD_DENSITY * horizon;
}

float cloudDensity(vec3 world, bool erosion) {
    float height;
    return cloudDensityWithHeight(world, erosion, height);
}

// Geometry receives only a soft direct-light shadow. Local lights and sky
// scattering retain their own contributions. Five samples cover the wider
// altitude range without skipping the narrower, displaced cloud groups.
float cloudProjectedShadowDirect(vec3 world, vec3 lightDirection) {
#if SIMPLE_DIMENSION != 0
    return 1.0;
#endif
    vec2 altitude = cloudAltitudeBounds();
    if (CLOUD_SHADOW_STRENGTH <= 0.0 || lightDirection.y <= 0.04 || world.y >= altitude.y) {
        return 1.0;
    }
    float entry = max((altitude.x - world.y) / lightDirection.y, 0.0);
    float exit = (altitude.y - world.y) / lightDirection.y;
    float stepLength = (exit - entry) / 5.0;
    float density = 0.0;
    for (int index = 0; index < 5; index++) {
        vec3 samplePosition = world + lightDirection * (entry + (float(index) + 0.5) * stepLength);
        density += cloudDensity(samplePosition, false);
    }
    float transmission = exp(-density * stepLength * 0.04 * CLOUD_OPACITY);
    return mix(1.0, transmission, CLOUD_SHADOW_STRENGTH);
}

#ifdef WORLD_GPU_BACKEND
// No world atlas in the conventional renderer baseline.

#ifndef SIMPLE_WORLD_STORAGE_GLSL
#define SIMPLE_WORLD_STORAGE_GLSL
uniform sampler2D colortex6;
uniform sampler2D noisetex;
#endif


// Points below the cloud layer on one light ray share its optical depth.
const float CLOUD_SHADOW_CELL = 2.0;

vec2 cloudShadowPlane(vec3 world, vec3 lightDirection) {
    return world.xz + lightDirection.xz * (cloudAltitudeBounds().x - world.y) / lightDirection.y;
}

vec2 cloudShadowGridOrigin(vec3 lightDirection) {
    return floor(cloudShadowPlane(cameraPosition, lightDirection) / CLOUD_SHADOW_CELL) * CLOUD_SHADOW_CELL;
}
#endif

float cloudProjectedShadow(vec3 world, vec3 lightDirection) {
#if defined(WORLD_GPU_BACKEND) && !defined(WORLD_BUILD_CLOUD_SHADOW)
    vec2 altitude = cloudAltitudeBounds();
    if (CLOUD_SHADOW_STRENGTH <= 0.0 || lightDirection.y <= 0.04 || world.y >= altitude.y) return 1.0;
    // Interior-cloud receivers need their remaining partial optical depth.
    if (world.y < altitude.x) {
        ivec4 region = worldRegion(WORLD_REGION_CLOUD_SHADOW);
        vec2 pixel = (cloudShadowPlane(world, lightDirection) - cloudShadowGridOrigin(lightDirection))
            / CLOUD_SHADOW_CELL + vec2(region.zw) * 0.5;
        vec2 border = min(pixel, vec2(region.zw) - pixel);
        if (min(border.x, border.y) >= 1.0) {
            vec4 cached = textureLod(colortex6,
                (vec2(region.xy) + pixel) / vec2(textureSize(colortex6, 0)), 0.0);
            if (cached.w == 1876.0) return cached.x;
        }
    }
#endif
    return cloudProjectedShadowDirect(world, lightDirection);
}

#endif

/*
 * Companion-provided light positions, independent cube-face shadows and diffuse
 * radiance volumes. All data remains linear HDR. Missing companion data selects
 * the existing Minecraft light-field fallback through companionReady = 0.
 * Block-light energy and wall occlusion always come from the native light field;
 * the companion supplies emitter hue (hue volume) and point-light visibility.
 */
#ifndef LIB_COMPANION_LIGHTING_GLSL
#define LIB_COMPANION_LIGHTING_GLSL
/* Compact local lighting. Fixed-size C5 is an image-only integer voxel store,
 * C10 holds three source identities, C11 their cached RGB transmission,
 * and C8 low-energy diffuse radiance. Direct RGB contributions remain separate
 * until the material consumer adds their independently shadowed radiance.
 */
#ifndef SIMPLE_CONVENTIONAL_LPV_GLSL
#define SIMPLE_CONVENTIONAL_LPV_GLSL



#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
uniform sampler2D colortex8;
// J9 restores every shadow draw attachment during native terrain submission.
// Fixed-size C5 is detached from the scene FBO and cannot be overwritten by
// raster outputs. Image reads also avoid J9's forced LINEAR sampler filtering.
layout(r32ui, binding=5) uniform uimage2D colorimg5;
uniform sampler2D colortex10;
uniform sampler2D colortex11;
const int LPV_HEADER_SIZE = 2;
const uint LPV_GLASS = 1u;
const uint LPV_SOLID = 2u;
const uint LPV_EMITTER = 3u;

ivec3 lpvShape() {
    return ivec3(COLOURED_VOLUME_SIZE, COLOURED_VOLUME_SIZE / 2, COLOURED_VOLUME_SIZE);
}

ivec3 lpvOrigin(vec3 camera) {
    return ivec3(floor(camera)) - lpvShape() / 2;
}

bool lpvInside(ivec3 cell) {
    return all(greaterThanEqual(cell, ivec3(0))) && all(lessThan(cell, lpvShape()));
}

int lpvIndex(ivec3 cell) {
    ivec3 shape = lpvShape();
    return cell.x + shape.x * (cell.y + shape.y * cell.z);
}

ivec3 lpvCell(int index) {
    ivec3 shape = lpvShape();
    return ivec3(index % shape.x, (index / shape.x) % shape.y, index / (shape.x * shape.y));
}

ivec2 lpvAddress(ivec3 cell) {
    int address = lpvIndex(cell) + LPV_HEADER_SIZE;
    int width = textureSize(colortex8, 0).x;
    return ivec2(address % width, address / width);
}

uint lpvVoxel(ivec3 cell) {
    if (!lpvInside(cell)) return 0u;
    int index = lpvIndex(cell);
    int width = imageSize(colorimg5).x;
    return imageLoad(colorimg5, ivec2(index % width, index / width)).r;
}

// 后半段保存原生顶点的几何投票：0未知、1只有完整方块角点、2出现内部顶点。
// 仅辅助隐藏反射面的置信度，不以整格几何替代原生反射表面。
bool lpvFullCubeGeometry(ivec3 cell) {
    if (!lpvInside(cell)) return false;
    ivec3 shape = lpvShape();
    int index = lpvIndex(cell) + shape.x * shape.y * shape.z;
    int width = imageSize(colorimg5).x;
    return imageLoad(colorimg5, ivec2(index % width, index / width)).r == 1u;
}

uint lpvKind(uint material) {
    return material >> 30u;
}

vec3 lpvColour(uint material) {
    return vec3(material & 255u, (material >> 8u) & 255u,
        (material >> 16u) & 255u) / 255.0;
}

float lpvEmission(uint material) {
    return float((material >> 24u) & 15u);
}

bool lpvOpaque(uint material) {
    return lpvKind(material) == LPV_SOLID
        || (lpvKind(material) == LPV_EMITTER && (material & (1u << 28u)) != 0u);
}

int lpvHeaderFrame(vec4 header) {
    return int(round(header.y)) + int(round(header.z)) * 1024;
}

// History carries its own origin. Rebase cells and source IDs together, rejecting
// reloads, resizes, teleports and floating-origin jumps before reading old data.
bool lpvHeaderValid(vec4 header) {
    int delta = (frameCounter - lpvHeaderFrame(header) + 720720) % 720720;
    vec4 sourceHeader = texelFetch(colortex10, ivec2(0), 0);
    ivec3 oldOrigin = ivec3(round(texelFetch(colortex10, ivec2(1, 0), 0).xyz));
    return header.w == 1961.0 && int(round(header.x)) == lpvShape().x && delta <= 1
        && all(equal(header, sourceHeader))
        && all(lessThanEqual(abs(lpvOrigin(cameraPosition) - oldOrigin), lpvShape() / 2));
}

vec3 lpvReadCell(ivec3 cell) {
    if (!lpvInside(cell)) return vec3(0.0);
    return max(texelFetch(colortex8, lpvAddress(cell), 0).rgb, vec3(0.0));
}

vec3 lpvSample(vec3 world) {
    if (!lpvHeaderValid(texelFetch(colortex8, ivec2(0), 0))) return vec3(0.0);
    vec3 position = world - vec3(lpvOrigin(cameraPosition)) - 0.5;
    ivec3 first = ivec3(floor(position));
    vec3 weight = fract(position);
    vec3 result = vec3(0.0);
    for (int corner = 0; corner < 8; corner++) {
        ivec3 offset = ivec3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        vec3 blend = mix(1.0 - weight, weight, vec3(offset));
        result += lpvReadCell(first + offset) * blend.x * blend.y * blend.z;
    }
    return result;
}

// Smooth finite-range attenuation depends on each emitter's own level. A nearby
// lamp cannot extend another colour's range by raising the native maximum level.
float lpvSourceEnergy(float distance, float emission) {
    float fraction = clamp(distance / max(emission, 1.0), 0.0, 1.0);
    float cutoff = 1.0 - fraction * fraction * fraction * fraction;
    return 4.0 * BLOCK_LIGHT_STRENGTH * emission / 15.0 * cutoff * cutoff
        / (1.0 + (BLOCK_LIGHT_FALLOFF / 6.0) * (distance + 2.0) * (distance + 2.0));
}

// Shared current occupancy supplies independent source visibility. Advance all
// tied axes so a corner-only contact cannot intermittently occlude a light.
vec3 lpvVisibility(vec3 receiver, ivec3 source) {
    vec3 endpoint = vec3(source) + vec3(0.5, 0.72, 0.5);
    vec3 delta = endpoint - receiver;
    ivec3 cell = ivec3(floor(receiver));
    ivec3 direction = ivec3(sign(delta));
    vec3 inverse = 1.0 / max(abs(delta), vec3(0.00001));
    vec3 boundary = vec3(cell) + step(vec3(0.0), delta);
    vec3 next = abs(boundary - receiver) * inverse;
    next = mix(vec3(1e20), next, notEqual(direction, ivec3(0)));
    vec3 transfer = vec3(1.0);
    for (int stepIndex = 0; stepIndex < 48; stepIndex++) {
        if (all(equal(cell, source))) return transfer;
        if (!lpvInside(cell)) return vec3(0.0);
        uint voxel = lpvVoxel(cell);
        if (lpvOpaque(voxel)) return vec3(0.0);
        if (lpvKind(voxel) == LPV_GLASS) transfer *= lpvColour(voxel);
        float crossing = min(next.x, min(next.y, next.z));
        if (crossing > 1.0) return transfer;
        bvec3 advance = lessThanEqual(next, vec3(crossing + 0.000001));
        cell += direction * ivec3(advance);
        next += inverse * vec3(advance);
    }
    return vec3(0.0);
}

// Blend candidate support over four cells in the receiving surface plane.
// A third source leaving one cell fades into the neighbour's third source;
// changing a discrete top-three list cannot instantly replace its colour.
// Additive light commutes with interpolation. Accumulate each cell directly to
// avoid dynamically indexed candidate arrays and per-pixel identity searches.
vec3 lpvSurfaceDirect(vec3 receiver, vec3 normal, out float explained) {
    vec3 direct = vec3(0.0);
    explained = 0.0;
    vec3 axis = abs(normal);
    vec3 plane = axis.x >= axis.y && axis.x >= axis.z ? vec3(0.0, 1.0, 1.0)
        : axis.y >= axis.z ? vec3(1.0, 0.0, 1.0) : vec3(1.0, 1.0, 0.0);
    vec3 first = plane.x > 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 second = plane.z > 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    vec3 shifted = receiver - 0.5 * plane;
    ivec3 base = ivec3(floor(shifted));
    vec2 fraction = vec2(dot(fract(shifted), first), dot(fract(shifted), second));
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            ivec3 cell = base + ivec3(first) * x + ivec3(second) * y;
            if (!lpvInside(cell)) continue;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                * (y == 0 ? 1.0 - fraction.y : fraction.y);
            if (weight <= 0.0) continue;
            ivec2 address = lpvAddress(cell);
            vec3 stored = texelFetch(colortex10, address, 0).rgb;
            float strongest = 0.0;
            for (int entry = 0; entry < 3; entry++) {
                int identity = int(round(stored[entry])) - 1;
                if (identity < 0) continue;
                ivec3 source = lpvCell(identity);
                uint material = lpvVoxel(source);
                if (lpvKind(material) != LPV_EMITTER) continue;
                vec3 ray = vec3(source) + vec3(0.5, 0.72, 0.5) - receiver;
                float distance = length(ray);
                float energy = lpvSourceEnergy(distance, lpvEmission(material));
                strongest = max(strongest, energy);
                float diffuse = 0.35 + 0.65 * max(dot(normal, ray / max(distance, 0.00001)), 0.0);
                vec3 colour = lpvColour(material);
                ivec2 cached = address + ivec2(0, entry * textureSize(colortex8, 0).y);
                vec3 transmission = texelFetch(colortex11, cached, 0).rgb;
                direct += colour * colour * energy * diffuse * transmission * weight;
            }
            explained += strongest * weight;
        }
    }
    return direct;
}

vec3 lpvBlockLight(vec3 viewPosition, vec3 normalView, vec3 nativeRadiance) {
    if (nativeRadiance.r <= 0.000001 || COLOURED_LIGHT_INTENSITY <= 0.0
        || !lpvHeaderValid(texelFetch(colortex8, ivec2(0), 0))) return nativeRadiance;
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 world = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz + cameraPosition;
    vec3 receiver = world + normal * 0.04 - vec3(lpvOrigin(cameraPosition));
    ivec3 cell = ivec3(floor(receiver));
    if (!lpvInside(cell)) return nativeRadiance;
    float explained;
    vec3 direct = lpvSurfaceDirect(receiver, normal, explained);
    // Storage follows integer blocks, but coverage follows the interpolated
    // camera. Advancing the storage origin must not jump the blend weight.
    // A one-block guard keeps the continuous fade inside both integer grids.
    vec3 relative = world + normal * 0.04 - cameraPosition;
    vec3 border = vec3(lpvShape()) * 0.5 - abs(relative);
    float coverage = smoothstep(1.0, 5.0, min(border.x, min(border.y, border.z)));
    float replaced = clamp(explained / max(nativeRadiance.r, 0.00001), 0.0, 1.0);
    vec3 indirect = vec3(0.0);
#if GI_QUALITY == 0
    indirect = lpvSample(world + normal * 0.7) * (0.16 * BLOCK_LIGHT_STRENGTH);
#endif
    vec3 local = nativeRadiance * (1.0 - replaced) + direct + indirect;
    return mix(nativeRadiance, local, coverage * COLOURED_LIGHT_INTENSITY);
}
#endif
#endif

/* Six directional radiance lobes in a camera-relative voxel volume. A lobe
 * travels through air and reflects at the exposed face of an opaque voxel.
 * Separate faces prevent a lit exterior from illuminating a sealed interior.
 * Headers store the field's own origin, independent of the direct-light passes.
 */
#ifndef SIMPLE_CONVENTIONAL_GI_GLSL
#define SIMPLE_CONVENTIONAL_GI_GLSL


#if GI_QUALITY > 0
uniform sampler2D colortex12;

ivec3 giDirection(int face) {
    ivec3 direction = ivec3(0);
    direction[face / 2] = face % 2 == 0 ? 1 : -1;
    return direction;
}

ivec2 giAddress(ivec3 cell, int face) {
    return lpvAddress(cell) + ivec2(0, face * textureSize(colortex8, 0).y);
}

ivec3 giStoredOrigin() {
    int height = textureSize(colortex8, 0).y;
    vec3 high = texelFetch(colortex12, ivec2(1, 0), 0).xyz;
    vec3 middle = texelFetch(colortex12, ivec2(1, height), 0).xyz;
    vec3 low = texelFetch(colortex12, ivec2(1, height * 2), 0).xyz;
    return ivec3(round(high * 1048576.0 + middle * 1024.0 + low));
}

bool giHistoryValid() {
    vec4 header = texelFetch(colortex12, ivec2(0), 0);
    int delta = (frameCounter - lpvHeaderFrame(header) + 720720) % 720720;
    ivec3 origin = giStoredOrigin();
    return header.w == 1973.0 && int(round(header.x)) == lpvShape().x
        && delta <= 1 && all(lessThanEqual(abs(lpvOrigin(cameraPosition) - origin), ivec3(2)));
}

// Reads always use the stored origin, so substeps and integer camera movement
// share the same mapping. Newly uncovered cells receive no stale radiance.
vec3 giRead(ivec3 cell, int face, ivec3 shift) {
    ivec3 previous = cell + shift;
    if (!lpvInside(cell) || !lpvInside(previous)) return vec3(0.0);
    return max(texelFetch(colortex12, giAddress(previous, face), 0).rgb, vec3(0.0));
}

// The six-lobe quadrature integrates the normal-facing radiance. Sampling only
// air prevents interpolation with the bright opposite face of a one-block wall.
vec3 giSurfaceIrradiance(vec3 viewPosition, vec3 normalView) {
    if (GI_STRENGTH <= 0.0 || !giHistoryValid()) return vec3(0.0);
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 relative = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
    vec3 world = relative + cameraPosition + normal * 0.55;
    vec3 position = world - vec3(lpvOrigin(cameraPosition)) - 0.5;
    ivec3 first = ivec3(floor(position));
    vec3 fraction = fract(position);
    vec3 irradiance = vec3(0.0);
    float total = 0.0;
    for (int corner = 0; corner < 8; corner++) {
        ivec3 offset = ivec3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        ivec3 cell = first + offset;
        if (!lpvInside(cell) || lpvOpaque(lpvVoxel(cell))) continue;
        vec3 blend = mix(1.0 - fraction, fraction, vec3(offset));
        float weight = blend.x * blend.y * blend.z;
        for (int axis = 0; axis < 3; axis++) {
            int face = axis * 2 + (normal[axis] > 0.0 ? 1 : 0);
            irradiance += texelFetch(colortex12, giAddress(cell, face), 0).rgb
                * abs(normal[axis]) * weight;
        }
        total += weight;
    }
    vec3 border = vec3(lpvShape()) * 0.5 - abs(relative + normal * 0.55);
    float coverage = smoothstep(1.0, 5.0, min(border.x, min(border.y, border.z)));
    return max(irradiance, vec3(0.0)) / max(total, 0.001) * GI_STRENGTH * coverage;
}
#endif
#endif






uniform sampler2D companionAtlas;
uniform sampler2D companionRadiance;
uniform int companionReady;
uniform vec3 companionOrigin;
uniform vec3 companionGiOrigin;
uniform vec3 companionHueOrigin;
uniform vec2 companionDimensions;

// Must match HueVolume.java: 8^3 bricks over a camera-centred 256x128x256 region,
// one indirection texel per brick, then 64x8-texel bricks in a slot pool.
const vec3 COMPANION_HUE_BRICKS = vec3(32.0, 16.0, 32.0);

// These options also configure the Mod's resource and scheduling budgets.
const int companionSizeOption = GI_VOLUME_SIZE;
const int companionShadowSizeOption = LOCAL_SHADOW_RESOLUTION;
const int companionShadowUpdatesOption = LOCAL_SHADOW_UPDATES;
const int companionPropagationOption = GI_PROPAGATION_STEPS;
const int companionWorkOption = GI_WORK_PER_FRAME;
const float companionRangeOption = LOCAL_LIGHT_RADIUS;
const float companionReflectanceOption = GI_REFLECTANCE;
const float companionIntervalOption = LIGHTING_UPDATE_INTERVAL;

// Older companion versions have no explicit dimensions and retain the original layout.
vec2 companionAtlasSize() {
    if (companionDimensions.x > 0.0) {
        return companionDimensions;
    }
    return vec2(24.0 * float(LOCAL_SHADOW_RESOLUTION),
        16.0 + ceil((float(LOCAL_LIGHT_COUNT) * 6.0 + 1.0) / 24.0) * float(LOCAL_SHADOW_RESOLUTION));
}

vec4 companionMeta(float index) {
    return texture(companionAtlas, vec2(index + 0.5, 0.5) / companionAtlasSize());
}

vec4 companionHeader() {
    return companionMeta(0.0);
}

bool hasCompanionLighting() {
#if ENABLE_COMPANION_LIGHTING == 0
    return false;
#else
    // Layout 4 light records; an older Mod falls back to native lighting.
    return companionReady == 1 && abs(companionHeader().r - 2026.0) < 0.5 && companionMeta(2.0).x > 3.5;
#endif
}

vec3 companionPosition(vec3 viewPosition, vec3 origin) {
    // The Mod subtracts OptiFine's camera offsets from both direct and GI origins.
    return (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz + cameraPosition - origin;
}

float companionVolumeWeight(vec3 position, float size, float margin) {
    vec3 border = min(position, vec3(size) - position);
    return smoothstep(0.0, margin, min(min(border.x, border.y), border.z));
}

// The volume follows the camera in four-block steps, so anything within
// reach = size / 2 - 4 of the camera is always inside it. Fading shadows by
// camera distance before that bound avoids pops when the volume moves.
float companionCameraFade(vec3 relative, float reach) {
    vec3 distance = abs(relative);
    return 1.0 - smoothstep(reach - 4.0, reach, max(max(distance.x, distance.y), distance.z));
}

// Row 0: block cell relative to companionOrigin and signed radius (negative
// until mapped), row 1: colour and emission, row 2: in-block offset and fade.
vec4 companionLight(int index, int row) {
    return texture(companionAtlas, vec2(float(4 + index * 3 + row) + 0.5, 0.5) / companionAtlasSize());
}

vec2 companionShadowUv(int tile, vec2 uv) {
    float side = float(LOCAL_SHADOW_RESOLUTION);
    vec2 corner = vec2(mod(float(tile), 24.0), floor(float(tile) / 24.0)) * side;
    corner.y += 16.0;
    float inner = side - 2.0;
    vec2 bounded = clamp(uv, vec2(0.5 / inner), vec2(1.0 - 0.5 / inner));
    return (corner + 1.0 + bounded * inner) / companionAtlasSize();
}

// Two filtered slice reads reconstruct the receiver-dependent RGB transmission.
vec3 companionTransmission(int index, vec3 position) {
    vec4 cacheData = companionMeta(2.0);
    if (cacheData.x < 1.5 || cacheData.w < 0.5) {
        return vec3(1.0);
    }
    float size = companionHeader().z;
    float side = size + 2.0;
    float rows = ceil(size / 8.0);
    vec2 corner = vec2(mod(float(index), cacheData.z) * side * 8.0,
        cacheData.y + floor(float(index) / cacheData.z) * side * rows);
    vec3 p = clamp(position - 0.5, vec3(0.0), vec3(size - 1.0));
    float first = floor(p.z);
    float second = min(first + 1.0, size - 1.0);
    vec2 a = corner + vec2(mod(first, 8.0), floor(first / 8.0)) * side;
    vec2 b = corner + vec2(mod(second, 8.0), floor(second / 8.0)) * side;
    vec3 lower = texture(companionAtlas, (a + p.xy + 1.5) / companionAtlasSize()).rgb;
    vec3 upper = texture(companionAtlas, (b + p.xy + 1.5) / companionAtlasSize()).rgb;
    return clamp(mix(lower, upper, fract(p.z)), vec3(0.0), vec3(1.0));
}

vec3 companionFaceDirection(int face, vec2 uv) {
    vec2 p = uv * 2.0 - 1.0;
    if (face == 0) return normalize(vec3(1.0, -p.y, -p.x));
    if (face == 1) return normalize(vec3(-1.0, -p.y, p.x));
    if (face == 2) return normalize(vec3(p.x, 1.0, p.y));
    if (face == 3) return normalize(vec3(p.x, -1.0, -p.y));
    if (face == 4) return normalize(vec3(p.x, -p.y, 1.0));
    return normalize(vec3(-p.x, -p.y, -1.0));
}

// Each source has its own six-face atlas allocation; no solar visibility enters
// this lookup. Four taps soften shadow edges without mixing neighbouring tiles.
vec3 companionShadow(int index, vec3 ray, float radius, vec3 normal, vec3 transmission) {
#if ENABLE_LOCAL_SHADOWS == 0
    return transmission;
#else
    vec3 absolute = abs(ray);
    vec2 uv;
    int face;
    float axis;
    if (absolute.x >= absolute.y && absolute.x >= absolute.z) {
        axis = absolute.x;
        face = ray.x > 0.0 ? 0 : 1;
        uv = ray.x > 0.0 ? vec2(-ray.z, -ray.y) : vec2(ray.z, -ray.y);
    } else if (absolute.y >= absolute.z) {
        axis = absolute.y;
        face = ray.y > 0.0 ? 2 : 3;
        uv = ray.y > 0.0 ? vec2(ray.x, ray.z) : vec2(ray.x, -ray.z);
    } else {
        axis = absolute.z;
        face = ray.z > 0.0 ? 4 : 5;
        uv = ray.z > 0.0 ? vec2(ray.x, -ray.y) : vec2(-ray.x, -ray.y);
    }
    uv = uv / max(axis, 0.001) * 0.5 + 0.5;
    vec3 result = vec3(0.0);
    float inner = float(LOCAL_SHADOW_RESOLUTION - 2);
    vec2 pixel = uv * inner - 0.5;
    vec2 fraction = fract(pixel);
    float distanceToReceiver = length(ray);
    float cosine = abs(dot(normal, ray)) / max(distanceToReceiver, 0.0001);
    // A PCF footprint may straddle two meeting receiver planes. Bound the
    // extrapolation and cover its world-space texel footprint, rather than
    // treating neighbouring wall texels as tiny occluders in the same room.
    float footprint = 2.0 * axis * LOCAL_SHADOW_SOFTNESS / inner;
    float bias = 0.012 + min(footprint * 0.6 / max(cosine, 0.35), 0.12);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            // 在相邻深度比较结果之间插值，保留四点预算并消除纹素阶梯。
            vec2 offset = (vec2(float(x), float(y)) - fraction)
                        * LOCAL_SHADOW_SOFTNESS / inner;
            vec2 sampleUv = clamp(uv + offset, vec2(0.5 / inner), vec2(1.0 - 0.5 / inner));
            vec2 pixelUv = (floor(sampleUv * inner) + 0.5) / inner;
            vec3 sampleRay = companionFaceDirection(face, pixelUv);
            float planeCosine = dot(sampleRay, normal);
            float receiverDistance = abs(planeCosine) > 0.0001
                ? dot(ray, normal) / planeCosine : length(ray);
            // Match each PCF sample to the receiver plane. A fixed central
            // distance causes severe acne for grazing point-light surfaces.
            float queryDepth = (max(min(receiverDistance, distanceToReceiver), 0.0) - bias) / radius;
            vec4 depths = texture(companionAtlas, companionShadowUv(index * 6 + face, pixelUv));
            float opaqueVisibility = step(queryDepth, depths.r);
            // B/A store the hit face axis and its signed plane distance. Compare
            // the central receiver to that plane, so a PCF tap on the adjoining
            // floor/wall cannot cast a false strip across a convex inner corner.
            // Old companions and cleared texels retain B=1 and use radial depth.
            if (depths.b < 0.9) {
                vec3 hitNormal = depths.b < 0.375 ? vec3(1, 0, 0)
                    : depths.b < 0.625 ? vec3(0, 1, 0) : vec3(0, 0, 1);
                float receiverPlane = dot(ray, hitNormal) / radius;
                float planeBias = 0.012 / radius + abs(depths.a) * 0.001;
                opaqueVisibility = receiverPlane * depths.a <= 0.0 ? 1.0
                    : step(abs(receiverPlane) - planeBias, abs(depths.a));
            }
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y);
            vec3 tint = queryDepth < depths.g ? vec3(1.0) : transmission;
            result += opaqueVisibility * tint * weight;
        }
    }
    return mix(transmission, result, LOCAL_SHADOW_STRENGTH);
#endif
}

// Unobstructed block light at a cell is the emitter level minus the Manhattan
// distance. Light that detours a few blocks around a pillar or short wall is
// still that emitter's shadow; only a long detour (another room, a doorway)
// means the native light arrived indirectly and must stay lit. No source
// explains more than the observed level.
float companionSourceWeight(float expected, float level) {
    if (expected <= 0.0) {
        return 0.0;
    }
    return blockLightAttenuation(min(expected, level) / 15.0)
         * (1.0 - smoothstep(5.0, 9.0, expected - level));
}

// rgb = radiance-weighted hue of the emitters whose propagated light reaches the
// cell, a = their weighted emission level (0 where none does). The Mod floods
// each hue with vanilla rules.
vec4 companionHue(vec3 position) {
    vec4 grid = companionMeta(3.0);
    vec3 extent = COMPANION_HUE_BRICKS * 8.0;
    if (grid.z < 0.5 || any(lessThan(position, vec3(0.0))) || any(greaterThanEqual(position, extent))) {
        return vec4(0.0);
    }
    vec2 size = companionAtlasSize();
    vec3 brick = floor(position / 8.0);
    float index = (brick.y * COMPANION_HUE_BRICKS.z + brick.z) * COMPANION_HUE_BRICKS.x + brick.x;
    float row = floor((index + 0.5) / size.x);
    // (0) unlit, (hue, -emission) single-hue brick, (slot, 0, 0, 1) pooled brick.
    vec4 entry = texture(companionAtlas, (vec2(index - row * size.x, grid.y + row) + 0.5) / size);
    if (entry.a < 0.0) {
        return vec4(entry.rgb, -entry.a);
    }
    if (entry.a < 0.5) {
        return vec4(0.0);
    }
    float slot = entry.r;
    float perRow = floor(size.x / 64.0);
    float slotRow = floor((slot + 0.5) / perRow);
    vec3 cell = floor(position) - brick * 8.0;
    vec2 texel = vec2((slot - slotRow * perRow) * 64.0 + cell.y * 8.0 + cell.x,
        grid.y + ceil(16384.0 / size.x) + slotRow * 8.0 + cell.z);
    return texture(companionAtlas, (texel + 0.5) / size);
}

// The hue grid holds one value per block, so a nearest lookup switches colour in
// whole-block steps where two emitters' light meets. Interpolate bilinearly over
// the four cells in the surface plane; only lit cells contribute, so walls and
// unlit cells beside the receiver do not pull the blend toward black.
vec4 companionSmoothHue(vec3 position, vec3 normal) {
    vec3 axis = abs(normal);
    vec3 plane = axis.x >= axis.y && axis.x >= axis.z ? vec3(0.0, 1.0, 1.0)
               : axis.y >= axis.z ? vec3(1.0, 0.0, 1.0) : vec3(1.0, 1.0, 0.0);
    vec3 first = plane.x > 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 second = plane.z > 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    // Cell centres sit at +0.5 along the tangents; the normal axis keeps its cell.
    vec3 shifted = position - 0.5 * plane;
    vec3 base = floor(shifted);
    vec2 fraction = vec2(dot(fract(shifted), first), dot(fract(shifted), second));
    vec4 sum = vec4(0.0);
    float total = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec4 tap = companionHue(base + first * float(x) + second * float(y) + 0.5);
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y) * step(0.5, tap.a);
            sum += tap * weight;
            total += weight;
        }
    }
    return total > 0.0 ? sum / total : vec4(0.0);
}

// Fraction of the native block light that reaches the receiver. Native light
// is the maximum over emitters, so a shadowed emitter removes only the share
// it explains beyond the strongest visible one. Unlisted light stays lit.
// tint weights the glass caches, which cover only the radiance volume.
vec3 companionVisibility(vec3 position, vec3 normal, float level, float observed, float tint) {
    vec3 cellPosition = floor(position + normal * 0.5) + 0.5;
    int count = int(companionHeader().y + 0.5);
    vec3 visible = vec3(0.0);
    float explained = 0.0;
    for (int index = 0; index < 128; index++) {
        if (index >= count || index >= LOCAL_LIGHT_COUNT) {
            break;
        }
        vec4 light = companionLight(index, 0);
        vec3 delta = abs(light.xyz + 0.5 - cellPosition);
        float manhattan = delta.x + delta.y + delta.z;
        // Emission never exceeds 15, so farther sources cannot reach this cell.
        if (manhattan >= 15.0) {
            continue;
        }
        float weight = companionSourceWeight(companionLight(index, 1).w - manhattan, level);
        if (weight <= 0.0) {
            continue;
        }
        explained = max(explained, weight);
        // visibility never exceeds 1, so a source no stronger than the visible
        // share already found cannot change the result; skip its shadow lookup.
        if (weight <= min(min(visible.r, visible.g), visible.b)) {
            continue;
        }
        vec4 anchor = companionLight(index, 2);
        vec3 ray = light.xyz + anchor.xyz - position;
        float squared = dot(ray, ray);
        float radius = abs(light.w);
        vec3 visibility = vec3(1.0);
        if (squared < radius * radius && squared > 0.0001) {
            // Only faces turned away from the emitter darken. Floors and walls lit
            // at grazing angles keep the isotropic native field, which is also the
            // far-camera fallback (visibility 1); a Lambert term here halved a
            // torch's lit area near the camera and doubled it again further away.
            float wrap = clamp(1.0 + 2.0 * dot(normal, ray) * inversesqrt(squared), 0.0, 1.0);
            vec3 transmission = light.w > 0.0 && tint > 0.0
                ? mix(vec3(1.0), companionTransmission(index, position), tint) : vec3(1.0);
            visibility = wrap <= 0.0 ? vec3(0.0)
                : light.w > 0.0 ? companionShadow(index, -ray, radius, normal, transmission) : transmission;
            // Maps belong to their lights, so no camera distance limits them; a
            // light entering or leaving the selection fades over a fraction of a second.
            visibility = mix(vec3(1.0), visibility * wrap, anchor.w);
        }
        visible = max(visible, visibility * weight);
    }
    if (explained <= 0.0) {
        return vec3(1.0);
    }
    return clamp(1.0 - (explained - visible) / max(observed, explained), 0.0, 1.0);
}

// One block-light model everywhere: native energy, grid hue, local visibility.
vec3 companionBlockLight(vec3 viewPosition, vec3 normalView, vec2 lmCoord, vec3 nativeRadiance) {
#if ENABLE_COLOURED_LIGHTING == 1
    return lpvBlockLight(viewPosition, normalView, nativeRadiance);
#endif
    // Unlit terrain has no propagated block energy to recolour or shadow.
    if (nativeRadiance.r <= 0.000001 || !hasCompanionLighting()) {
        return nativeRadiance;
    }
    float level = lightmapLevel(lmCoord.x) * 15.0;
    float observed = blockLightAttenuation(level / 15.0);
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 world = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz + cameraPosition;
    // The native tint is (1,g,b), so its red channel is the uncoloured energy.
    vec3 colour = nativeRadiance / nativeRadiance.r;
    vec3 relative = world - cameraPosition;
    float energy = nativeRadiance.r;
#if ENABLE_COLOURED_LIGHTING == 1
    // Light levels are stored in the air cell in front of the surface. The hue
    // region keeps at least 96 (48 vertical) blocks around the camera.
    vec4 hue = companionSmoothHue(world + normal * 0.5 - companionHueOrigin, normal);
    vec3 far = abs(relative);
    float coverage = step(0.5, hue.a)
        * (1.0 - smoothstep(80.0, 96.0, max(far.x, far.z))) * (1.0 - smoothstep(32.0, 48.0, far.y));
    colour = mix(colour, hue.rgb, coverage);
    // The native field reads every level as distance from a level-15 torch, so
    // weaker emitters (soul torch 10, redstone torch 7) looked nearly unlit. With
    // the emitter's level known, attenuate over its own range and scale the
    // intensity by level. The native field puts a torch's own cell two blocks
    // from its source; every emitter keeps that near field, so torches (14) and
    // brighter emitters keep exactly the native energy instead of a hot spot.
    float ownLevel = level;
#if SMOOTH_BLOCK_LIGHT == 0
    ownLevel = floor(ownLevel + 0.5);
#endif
    float own = 4.0 * BLOCK_LIGHT_STRENGTH * min(hue.a, 15.0) / 15.0
              * emitterLightAttenuation(ownLevel, min(hue.a, 15.0), 2.0);
    energy = mix(energy, max(energy, own), coverage);
#endif
    vec3 position = world - companionOrigin;
    // Glass tint caches follow the camera-centred volume; fade them like GI.
    float size = companionHeader().z;
    float tint = companionCameraFade(relative, size * 0.5 - 4.0) * companionVolumeWeight(position, size, 1.0);
    vec3 visibility = companionVisibility(position, normal, level, observed, tint);
    return colour * visibility * energy;
}

// Bilinear interpolation within padded x/y slices plus interpolation between
// z slices gives continuous 3D radiance with six gtexture reads for all RGB bands.
vec4 companionSh(vec3 position, float size, float band) {
    vec3 p = clamp(position - 0.5, vec3(0.0), vec3(size - 1.0));
    float first = floor(p.z);
    float second = min(first + 1.0, size - 1.0);
    float side = size + 2.0;
    float rows = ceil(size / 8.0);
    vec2 dimensions = vec2(side * 8.0, side * rows * 3.0);
    vec2 a = vec2(mod(first, 8.0), floor(first / 8.0)) * side;
    vec2 b = vec2(mod(second, 8.0), floor(second / 8.0)) * side;
    a.y += band * rows * side;
    b.y += band * rows * side;
    vec4 lower = texture(companionRadiance, (a + p.xy + 1.5) / dimensions);
    vec4 upper = texture(companionRadiance, (b + p.xy + 1.5) / dimensions);
    return mix(lower, upper, fract(p.z));
}

vec3 companionIndirect(vec3 viewPosition, vec3 normalView) {
#if GI_QUALITY > 0
    return giSurfaceIrradiance(viewPosition, normalView);
#endif
#if GI_BOUNCES == 0
    return vec3(0.0);
#else
    if (!hasCompanionLighting() || companionHeader().w < 0.5) {
        return vec3(0.0);
    }
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 position = companionPosition(viewPosition, companionGiOrigin) + normal * 0.65;
    float size = companionHeader().z;
    // The volume moves in four-block steps; fading by its border made the
    // bounce light jump with each step. Fade by camera distance instead, which
    // is continuous; the border term only guards a volume still being rebuilt.
    vec3 relative = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
    float weight = companionCameraFade(relative, size * 0.5 - 4.0) * companionVolumeWeight(position, size, 2.0);
    if (weight <= 0.0) {
        return vec3(0.0);
    }
    vec4 basis = vec4(0.886227, -normal * 1.023327);
    return max(vec3(dot(companionSh(position, size, 0.0), basis),
                    dot(companionSh(position, size, 1.0), basis),
                    dot(companionSh(position, size, 2.0), basis)), vec3(0.0)) * GI_STRENGTH * weight;
#endif
}

#endif


/* 本文件用到的 uniform（全部在 lib/uniforms.glsl 中声明）：
 *   sunPosition               太阳在视图空间的方向（长度约 100）
 *   moonPosition              月亮在视图空间的方向
 *   gbufferModelViewInverse   视图空间 -> 世界空间，用来求太阳相对地平线的高度
 *   skyColor                  天空颜色，用作环境光染色
 */


/* ---------------------------------------------------------------------------
 * 太阳几何
 * ------------------------------------------------------------------------ */

// 太阳在世界空间中的方向。
// mat3(...) 取 4x4 矩阵的左上 3x3 部分，等于只做旋转、不做平移。
vec3 getSunDirWorld() {
    return safeNormalize(mat3(gbufferModelViewInverse) * sunPosition, vec3(0.0, 1.0, 0.0));
}

// 太阳相对地平线的高度角：+1 = 正头顶，0 = 地平线，-1 = 正下方（午夜）。
// 这是判断昼夜、决定光照颜色与强度的核心变量。
float getSunHeight() {
    return getSunDirWorld().y;
}

// 白天的程度：0 = 完全夜晚，1 = 完全白天。
// smoothstep 让日出/日落有一个平滑的过渡带，而不是突然切换。
// 让暮光区覆盖地平线两侧，避免太阳刚越过地平线就骤然变色。
float getDayFactor() {
#if SIMPLE_DIMENSION != 0
    return 1.0;
#endif
    return smoothstep(-0.12, 0.16, getSunHeight());
}

float getNightFactor() {
#if SIMPLE_DIMENSION != 0
    return 0.0;
#endif
    return 1.0 - smoothstep(-0.16, 0.12, getSunHeight());
}


/* ---------------------------------------------------------------------------
 * 光源方向与颜色
 * ------------------------------------------------------------------------ */

// 阴影贴图当前使用的光源方向，由加载器提供。
// 太阳与月亮大致相反，不能直接插值两者的方向：暮光时会互相抵消。
vec3 getLightDirView() {
    return safeNormalize(shadowLightPosition, vec3(0.0, 1.0, 0.0));
}

// 日光颜色在低太阳高度时变暖；亮度随暮光平滑淡入。
vec3 getSunLightColor() {
#if SIMPLE_DIMENSION != 0
    return vec3(0.0);
#endif
    // 直射光须与实际阴影光源的半球一致；暮光环境光仍保留较宽的昼夜过渡。
    float elevation = getSunHeight();
    return atmosphereDirectTransmittance(elevation)
         * smoothstep(0.0, 0.04, elevation) * SUNLIGHT_STRENGTH
         * mix(1.0, 0.20, weatherRainAmount());
}

// 月光独立淡出，避免把两侧光源方向混成零向量。
vec3 getMoonLightColor() {
#if SIMPLE_DIMENSION != 0
    return vec3(0.0);
#endif
    return vec3(0.80, 0.86, 1.00) * MOONLIGHT_STRENGTH
         * smoothstep(0.0, 0.04, skyMoonDirection().y) * getNightFactor()
         * (0.08 + 0.92 * lunarIlluminatedFraction()) * mix(1.0, 0.35, weatherRainAmount());
}

// 环境光颜色：天空的散射光。
// 直接把 skyColor 拿来用效果太艳，和光照贴图做插值后更接近 MC 的观感。
vec3 getAmbientColor(vec3 lmColor) {
    vec3 skyLinear = toLinearSpace(skyColor);
    return mix(lmColor, skyLinear * luma(lmColor), SKY_TINT)
         * AMBIENT_STRENGTH;
}


/* ---------------------------------------------------------------------------
 * 主光照函数
 * ------------------------------------------------------------------------ */

/*
 * 计算一个不透明表面的最终颜色。
 *
 * 参数：
 *   albedo        表面反照率（贴图颜色 × 顶点颜色）
 *   normalView    视图空间法线，必须已归一化
 *   lmCoord       光照贴图坐标，x = 方块光等级，y = 天空光等级，范围 [0,1]
 *   shadowFactor  阴影系数，1 = 完全受光，0 = 完全被遮挡
 *
 * 返回值：线性空间的颜色，可能大于 1（HDR），由后处理阶段负责压回显示范围。
 */
// 天空散射接收环境遮蔽；局部光独立累加，太阳阴影不会削弱火把的辐射。
vec3 surfaceAmbient(vec2 lmCoord, float occlusion) {
#if SIMPLE_DIMENSION != 0
    // Direction-dependent dimension fill is added by surfaceAmbientAt().
    return blockLightRadiance(lmCoord) * mix(clamp(occlusion, 0.0, 1.0), 1.0, 0.80);
#endif
    vec3 local = blockLightRadiance(lmCoord);
    vec3 sky = skyLightRadiance(lmCoord);
    // 天空颜色只提供色温；归一亮度后再染色，避免一次颜色插值又压暗漫射能量。
    vec3 skyInput = toLinearSpace(skyColor);
    float skyLuminance = luma(skyInput);
    vec3 skyHue = skyLuminance > 0.0001 ? skyInput / skyLuminance : vec3(1.0);
    skyHue = weatherSkyRadiance(skyHue);
    skyHue /= max(luma(skyHue), EPSILON);
    vec3 skyTinted = sky * mix(vec3(1.0), skyHue, SKY_TINT);
    float localOcclusion = mix(clamp(occlusion, 0.0, 1.0), 1.0, 0.80);
    vec3 deepAmbient = isEyeInWater == 1
        ? vec3(0.60, 0.80, 1.0) * UNDERWATER_MIN_VISIBILITY : vec3(0.0);
    float skyVisibility = smoothstep(0.08, 0.85, lightmapLevel(lmCoord.y));
    // 夜间天空散射保持偏冷，形成稳定的暗部基底；方块暖光独立叠加。
    vec3 nightTint = vec3(0.76, 0.86, 1.0);
    nightTint /= luma(nightTint);
    skyTinted *= mix(vec3(1.0), nightTint, getNightFactor());
    skyTinted *= mix(1.0, 0.88, weatherRainAmount());
    vec3 nightAmbient = nightTint * NIGHT_AMBIENT_STRENGTH
                      * getNightFactor() * skyVisibility;
    float skyStrength = mix(0.08, 0.56, getDayFactor());
    return (lightmapDarkFloor() * occlusion + deepAmbient * occlusion + nightAmbient * occlusion
            + skyTinted * occlusion * skyStrength)
         * AMBIENT_STRENGTH + local * localOcclusion;
}

// 方块光的传播与能量始终来自原版光照场；配套数据只提供色相与点光可见度。
vec3 surfaceAmbientAt(vec2 lmCoord, float occlusion, vec3 normalView, vec3 viewPosition) {
    vec3 ambient = surfaceAmbient(lmCoord, occlusion);
    float localOcclusion = mix(clamp(occlusion, 0.0, 1.0), 1.0, 0.80);
    vec3 nativeBlock = blockLightRadiance(lmCoord);
    ambient += (companionBlockLight(viewPosition, normalView, lmCoord, nativeBlock) - nativeBlock)
             * localOcclusion;
    ambient += companionIndirect(viewPosition, normalView) * mix(occlusion, 1.0, 0.5);
    // 为无天光的矿洞保留可导航亮度；已有照明达到目标时不继续增亮。
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normalView);
    #if SIMPLE_DIMENSION != 0
    ambient += dimensionAmbient(normalWorld) * occlusion * AMBIENT_STRENGTH;
#endif
#if SIMPLE_DIMENSION == 0
    float exposure = smoothstep(0.08, 0.85, lightmapLevel(lmCoord.y));
    ambient += twilightIrradiance(normalWorld) * exposure * occlusion * AMBIENT_STRENGTH;
#endif
    float shape = 0.75 + 0.25 * max(normalWorld.y, 0.0);
    float contact = mix(0.55, 1.0, clamp(occlusion, 0.0, 1.0));
    float target = MIN_AMBIENT_LIGHT * shape * contact;
    ambient += vec3(max(target - luma(ambient), 0.0));
    return ambient;
}

// shadowFactor 为日月光的 RGB 传递：彩色玻璃染色，发光方块照亮自身投影。
vec3 computeSurfaceLighting(vec3 albedo, vec3 normalView, vec2 lmCoord,
                           vec3 shadowFactor, float occlusion, vec3 viewPosition) {
#if SIMPLE_DIMENSION != 0
    return albedo * surfaceAmbientAt(lmCoord, occlusion, normalView, viewPosition);
#endif
    vec3 sunDir = safeNormalize(sunPosition, vec3(0.0, 1.0, 0.0));
    vec3 moonDir = safeNormalize(moonPosition, vec3(0.0, 1.0, 0.0));
    float skyLevel = lightmapLevel(lmCoord.y);
    float directVisibility = smoothstep(0.60, 0.96, skyLevel);
    vec3 direct = getSunLightColor() * max(dot(normalView, sunDir), 0.0)
                + getMoonLightColor() * max(dot(normalView, moonDir), 0.0);
    float cloudVisibility = 1.0;
    // 只为实际能到达接收面的日月直射积分云影。背向当前光源、全遮挡与零强度
    // 都没有云影贡献；局部方块光和 GI 仍独立计算。保留非零透射色，避免丢失玻璃滤色。
    if (directVisibility > 0.001 && any(greaterThan(direct * shadowFactor, vec3(0.0)))) {
        vec3 world = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz + cameraPosition;
        cloudVisibility = cloudProjectedShadow(world, normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
    }
    direct *= cloudVisibility;
    vec3 illumination = surfaceAmbientAt(lmCoord, occlusion, normalView, viewPosition)
                      + direct * shadowFactor * directVisibility;
    return albedo * illumination;
}

vec3 computeSurfaceLighting(vec3 albedo, vec3 normalView, vec2 lmCoord,
                           float shadowFactor, float occlusion, vec3 viewPosition) {
    return computeSurfaceLighting(albedo, normalView, lmCoord, vec3(shadowFactor), occlusion, viewPosition);
}

// 保留普通几何体的调用接口；地形额外传入已分离的原版 AO。
vec3 computeLighting(vec3 albedo, vec3 normalView, vec3 lmColor,
                     vec2 lmCoord, vec3 shadowFactor, vec3 viewPosition) {
    return computeSurfaceLighting(albedo, normalView, lmCoord, shadowFactor, 1.0, viewPosition);
}

vec3 computeLighting(vec3 albedo, vec3 normalView, vec3 lmColor,
                     vec2 lmCoord, float shadowFactor, vec3 viewPosition) {
    return computeSurfaceLighting(albedo, normalView, lmCoord, vec3(shadowFactor), 1.0, viewPosition);
}


/* ---------------------------------------------------------------------------
 * 高光（Blinn-Phong 近似）
 *   只在需要"湿润/光滑"观感的表面调用，例如水面和冰。
 *   真正的 PBR 会用 GGX 分布 + 几何遮蔽项，这里先给出最简单的版本。
 * ------------------------------------------------------------------------ */
vec3 computeSpecular(vec3 normalView, vec3 viewPos, vec3 specularColor, float glossiness) {
    // 当前水面高光只模拟太阳，并在调用方随日光权重淡出。
    // 直接取太阳方向，可避免阴影贴图切换到月亮时高光跳变。
    vec3 lightDirView = safeNormalize(sunPosition, vec3(0.0, 1.0, 0.0));

    // 视线方向：从表面指向摄像机。视图空间里摄像机就在原点。
    vec3 viewDir = safeNormalize(-viewPos, vec3(0.0, 0.0, 1.0));

    // 半程向量：光线方向与视线方向的角平分线。
    // 它与法线的夹角越小，说明高光越强 —— 这是 Blinn-Phong 相对
    // 原始 Phong 模型的改进，能避免掠射角下的高光断裂。
    vec3 halfDir = safeNormalize(lightDirView + viewDir, normalView);

    float NdotH = clamp(dot(normalView, halfDir), 0.0, 1.0);

    // glossiness 越大，高光越集中越锐利。指数运算开销不高，可以放心用。
    return specularColor * pow(NdotH, glossiness);
}

#endif  // LIB_LIGHTING_GLSL

/* 日月阴影入口。返回 RGB 光传递：不透明遮挡为 0，彩色玻璃按透射色染色，
 * 发光方块以自身颜色按遮挡距离照亮它投下的阴影。
 */
#ifndef LIB_SHADOW_GLSL
#define LIB_SHADOW_GLSL
/* 共享 PCSS 近似：遮挡搜索决定半影宽度，接收面斜率补偿避免掠射光的阴影脱离。 */
#ifndef LIB_SHADOW_FILTER_GLSL
#define LIB_SHADOW_FILTER_GLSL
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



// 透明几何在 shadowtex0，仅不透明几何在 shadowtex1；shadowcolor0 记录最近投影体类别。
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;

// 阴影纹素中心先做深度比较，再插值比较结果，供体积光与水体共享。
float filteredShadowVisibility(sampler2D depthMap, vec2 uv, float receiver) {
    float resolution = shadowTextureResolution();
    float texel = 1.0 / resolution;
    vec2 pixel = uv * resolution - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    float visibility = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 sampleUv = (base + vec2(float(x), float(y)) + 0.5) * texel;
            sampleUv = clamp(sampleUv, vec2(texel * 0.5), vec2(1.0 - texel * 0.5));
            float depth = texture(depthMap, sampleUv).r;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y);
            visibility += step(receiver, depth) * weight;
        }
    }
    return visibility;
}

// 斜率补偿必须使用实际读到的阴影纹素中心，避免最近邻采样误差变成自阴影。
vec2 shadowTexelCenter(vec2 uv) {
    float resolution = shadowTextureResolution();
    return (clamp(floor(uv * resolution), vec2(0.0), vec2(resolution - 1.0))
            + 0.5) / resolution;
}

vec2 shadowDiskOffset(int index, int count) {
    float angle = float(index) * 2.39996323;
    float radius = sqrt((float(index) + 0.5) / float(count));
    return vec2(cos(angle), sin(angle)) * radius;
}

// 屏幕导数转换为阴影 UV 上的接收面深度斜率。
vec2 shadowReceiverGradient(vec3 coordinate) {
    vec3 dx = dFdx(coordinate);
    vec3 dy = dFdy(coordinate);
    float first = dx.x * dy.y;
    float second = dx.y * dy.x;
    float determinant = first - second;
    // 用相对退化判据，避免高分辨率或近处表面的有效小导数被直接清零。
    float scale = max(abs(first), abs(second));
    if (abs(determinant) <= scale * 0.00001) {
        return vec2(0.0);
    }
    return clamp(vec2(dx.z * dy.y - dy.z * dx.y,
                      dy.z * dx.x - dx.z * dy.x) / determinant,
                 vec2(-3.0), vec2(3.0));
}

// 公共接收端设置：畸变后的阴影坐标、接收面斜率补偿、偏移后的接收深度与距离淡出。
bool prepareDirectionalShadow(vec4 clipPosition, vec3 normalView, float viewDistance,
                              out vec3 uv, out vec2 gradient, out float receiver,
                              out float fade, out float distortion) {
    // 在插值后畸变，保持采样投影与实际接收点一致。
    vec3 clip = clipPosition.xyz / max(clipPosition.w, EPSILON);
    distortion = (1.0 - SHADOW_MAP_BIAS) + length(clip.xy) * SHADOW_MAP_BIAS;
    uv = distortShadow(clip) * 0.5 + 0.5;
    gradient = shadowReceiverGradient(uv);
    fade = 1.0 - smoothstep(shadowDistance * 0.75, shadowDistance * 0.95, viewDistance);
    float incidence = max(dot(normalView, getLightDirView()), 0.0);
    receiver = uv.z;
    if (clipPosition.w <= 0.0 || fade <= 0.0 || incidence <= 0.001
        || any(lessThan(uv, vec3(0.0))) || any(greaterThan(uv, vec3(1.0)))) {
        return false;
    }
    float texel = 1.0 / shadowTextureResolution();
    // 栅格化后的畸变三角形仍有有限精度误差；保留有界基础偏移，
    // 不再按掠射角放大八倍，样本之间的斜率由接收面补偿处理。
    float bias = max(0.000001,
        min(SHADOW_BIAS * (0.5 + 0.5 * distortion), texel * 0.75));
    // 半纹素覆盖内的深度变化作为有界容差，修正低角度平地自遮挡。
    bias += 0.5 * texel * (abs(gradient.x) + abs(gradient.y));
    receiver = uv.z - bias;
    return true;
}

// 正交投影的深度差对应沿光线的世界距离（方块）。
float shadowDepthToBlocks(float depth) {
    return depth * 2.0 / max(abs(shadowProjection[2][2]), EPSILON);
}

// 畸变后阴影 UV 中一个方块的近似跨度。
float shadowUvPerBlock(float distortion) {
    return 0.5 * max(abs(shadowProjection[0][0]), abs(shadowProjection[1][1]))
         / max(distortion, 0.05);
}

// PCSS 滤波半径：遮挡距离越远半影越宽。
float shadowFilterRadius(float separation, float distortion) {
    float texel = 1.0 / shadowTextureResolution();
    float uvPerBlock = shadowUvPerBlock(distortion);
    return clamp(separation * 0.00465 * uvPerBlock * float(SHADOW_SOFTNESS),
                 texel * 0.7, texel * 8.0 * float(SHADOW_SOFTNESS));
}

float sampleSoftDirectionalShadow(sampler2D depthMap, vec4 clipPosition,
                                  vec3 normalView, float viewDistance) {
#if ENABLE_SHADOWS == 0
    return 1.0;
#else
    vec3 uv;
    vec2 gradient;
    float receiver;
    float fade;
    float distortion;
    if (!prepareDirectionalShadow(clipPosition, normalView, viewDistance,
                                  uv, gradient, receiver, fade, distortion)) {
        return 1.0;
    }
    float texel = 1.0 / shadowTextureResolution();
#if SHADOW_SOFTNESS == 0
    vec2 sampleUv = shadowTexelCenter(uv.xy);
    float visibility = step(receiver + dot(gradient, sampleUv - uv.xy),
                            texture(depthMap, sampleUv).r);
#else
    const int blockerSamples = SHADOW_SOFTNESS == 1 ? 5 : 9;
    const int filterSamples = SHADOW_SOFTNESS == 1 ? 8 : 12;
    float blockerSum = 0.0;
    float blockers = 0.0;
    float searchRadius = texel * (4.0 + 4.0 * float(SHADOW_SOFTNESS));
    for (int index = 0; index < blockerSamples; index++) {
        vec2 offset = index == 0 ? vec2(0.0)
            : shadowDiskOffset(index - 1, blockerSamples - 1) * searchRadius;
        vec2 sampleUv = shadowTexelCenter(uv.xy + offset);
        float sampleDepth = texture(depthMap, sampleUv).r;
        float centerDepth = sampleDepth - dot(gradient, sampleUv - uv.xy);
        if (centerDepth < receiver) {
            blockerSum += centerDepth;
            blockers += 1.0;
        }
    }
    if (blockers < 0.5) {
        return 1.0;
    }
    float separation = shadowDepthToBlocks(max(receiver - blockerSum / blockers, 0.0));
    float radius = shadowFilterRadius(separation, distortion);
    float visibility = 0.0;
    for (int index = 0; index < filterSamples; index++) {
        vec2 offset = shadowDiskOffset(index, filterSamples) * radius;
        vec2 sampleUv = shadowTexelCenter(uv.xy + offset);
        float depth = texture(depthMap, sampleUv).r;
        visibility += step(receiver + dot(gradient, sampleUv - uv.xy), depth);
    }
    visibility /= float(filterSamples);
#endif
    return mix(1.0, visibility, fade);
#endif
}

#endif


// 发光方块对其阴影的补光：紧贴光源处几乎完全照亮，约 15 格（最大光照等级）后消失。
const float SHADOW_EMITTER_FILL = 0.85;

// shadowcolor0 只记录离太阳最近的投影体，看不到发光体背后的实体。
// 发光体在阴影图上只占很小的面积：若周围一格内的光线在到达接收面前已被不透明体挡住，
// 说明发光体与接收点之间还隔着实体（如方块顶上的火把投到方块背后），此时不补光。
bool shadowEmitterOccluded(vec2 sampleUv, float receiver, vec2 gradient, float uvPerBlock) {
    // 接收面起伏半格以内不算遮挡。
    float margin = 0.25 * abs(shadowProjection[2][2]);
    for (int index = 0; index < 6; index++) {
        vec2 tapUv = shadowTexelCenter(sampleUv + shadowDiskOffset(index, 6) * uvPerBlock);
        if (abs(texture(shadowcolor0, tapUv).a - 0.75) < 0.125) {
            continue;
        }
        float tapReceiver = receiver + dot(gradient, tapUv - sampleUv);
        if (texture(shadowtex1, tapUv).r < tapReceiver - margin) {
            return true;
        }
    }
    return false;
}

// 单个滤波样本的 RGB 传递。仅在 shadowtex0 显示遮挡时读取类别，未遮挡样本不增加开销。
vec3 shadowSampleTransfer(vec2 sampleUv, float receiver, float depth,
                          vec2 gradient, float uvPerBlock) {
    if (receiver <= depth) {
        return vec3(1.0);
    }
    vec4 caster = texture(shadowcolor0, sampleUv);
    // 只认 shadow.fsh 写入的类别标记；其余 alpha（含白色清屏值）都是不透明遮挡。
    if (abs(caster.a - 0.75) < 0.125) {
        if (shadowEmitterOccluded(sampleUv, receiver, gradient, uvPerBlock)) {
            return vec3(0.0);
        }
        float separation = shadowDepthToBlocks(receiver - depth);
        vec3 hue = toLinearSpace(caster.rgb);
        hue /= max(max(hue.r, hue.g), max(hue.b, 0.001));
#if ENABLE_COLOURED_LIGHTING == 0
        hue = vec3(1.0);
#endif
        return hue * SHADOW_EMITTER_FILL * (1.0 - smoothstep(1.5, 15.0, separation));
    }
    // 半透明投影体之后若还有不透明遮挡，则仍为完整阴影。
    if (abs(caster.a - 0.5) < 0.125 && receiver <= texture(shadowtex1, sampleUv).r) {
#if ENABLE_COLOURED_LIGHTING == 0
        return vec3(luma(caster.rgb));
#else
        return caster.rgb;
#endif
    }
    return vec3(0.0);
}

vec3 getSurfaceShadowFactor(vec4 shadowClipPos, vec3 normalView, float viewDistance,
                            float lightmapY) {
#if SIMPLE_DIMENSION != 0
    return vec3(1.0);
#endif
#if ENABLE_SHADOWS == 0
    return vec3(1.0);
#else
    vec3 uv;
    vec2 gradient;
    float receiver;
    float fade;
    float distortion;
    // Keep derivatives outside the SIMPLE_VARYING exposure branch. A surface receiving
    // no direct sky light cannot use solar visibility in either diffuse or GGX.
    bool prepared = prepareDirectionalShadow(shadowClipPos, normalView, viewDistance,
                                             uv, gradient, receiver, fade, distortion);
#if DEBUG_VIEW == 0
    if (lightmapLevel(lightmapY) <= 0.60) {
        return vec3(1.0);
    }
#endif
    if (!prepared) {
        return vec3(1.0);
    }
    float texel = 1.0 / shadowTextureResolution();
#if SHADOW_SOFTNESS == 0
    vec2 sampleUv = shadowTexelCenter(uv.xy);
    vec3 transfer = shadowSampleTransfer(sampleUv, receiver + dot(gradient, sampleUv - uv.xy),
                                         texture(shadowtex0, sampleUv).r,
                                         gradient, shadowUvPerBlock(distortion));
#else
    const int blockerSamples = SHADOW_SOFTNESS == 1 ? 5 : 9;
    const int filterSamples = SHADOW_SOFTNESS == 1 ? 8 : 12;
    float blockerSum = 0.0;
    float blockers = 0.0;
    float searchRadius = texel * (4.0 + 4.0 * float(SHADOW_SOFTNESS));
    for (int index = 0; index < blockerSamples; index++) {
        vec2 offset = index == 0 ? vec2(0.0)
            : shadowDiskOffset(index - 1, blockerSamples - 1) * searchRadius;
        vec2 sampleUv = shadowTexelCenter(uv.xy + offset);
        float centerDepth = texture(shadowtex0, sampleUv).r - dot(gradient, sampleUv - uv.xy);
        if (centerDepth < receiver) {
            blockerSum += centerDepth;
            blockers += 1.0;
        }
    }
    if (blockers < 0.5) {
        return vec3(1.0);
    }
    float separation = shadowDepthToBlocks(max(receiver - blockerSum / blockers, 0.0));
    float radius = shadowFilterRadius(separation, distortion);
    float uvPerBlock = shadowUvPerBlock(distortion);
    vec3 transfer = vec3(0.0);
    for (int index = 0; index < filterSamples; index++) {
        vec2 sampleUv = shadowTexelCenter(uv.xy + shadowDiskOffset(index, filterSamples) * radius);
        transfer += shadowSampleTransfer(sampleUv, receiver + dot(gradient, sampleUv - uv.xy),
                                         texture(shadowtex0, sampleUv).r,
                                         gradient, uvPerBlock);
    }
    transfer /= float(filterSamples);
#endif
    return mix(vec3(1.0), transfer, fade);
#endif
}

// Other geometry retains its existing entry point and full shadow evaluation.
vec3 getShadowFactor(vec4 shadowClipPos, vec3 normalView, float viewDistance) {
    return getSurfaceShadowFactor(shadowClipPos, normalView, viewDistance, 1.0);
}

#endif

/*
================================================================================
 lib/varyings.glsl —— 顶点着色器 -> 片元着色器 的数据传递
================================================================================
 SIMPLE_VARYING 是顶点着色器的输出、片元着色器的输入，GPU 会在三角形内部做插值。

 顶点和片元两侧的 SIMPLE_VARYING 声明【必须完全一致】（名称、类型、顺序无所谓但
 名称必须相同），否则链接会失败或数据错乱。为了避免两边写不一样，
 本项目把 SIMPLE_VARYING 集中在这里，两侧都 #include 这一份。

 插值的含义：如果一个三角形三个顶点分别是红、绿、蓝，中间像素拿到的
 是三者按距离加权的结果 —— 这就是为什么渐变能自动生效。
================================================================================
*/
#ifndef LIB_VARYINGS_GLSL
#define LIB_VARYINGS_GLSL

// 贴图坐标，来自 gl_TextureMatrix[0] * gl_MultiTexCoord0。
SIMPLE_VARYING vec2 vTexCoord;
// 原生四边形的图集中心与半尺寸，限定POM采样不越过当前贴图。
SIMPLE_VARYING vec4 vPbrTile;

// 顶点颜色，来自 gl_Color。包含了方块的生物群系染色（草/树叶的绿色）
// 以及一些特殊渲染的颜色信息。
SIMPLE_VARYING vec4 vColor;

// 光照贴图坐标，来自 gl_TextureMatrix[1] * gl_MultiTexCoord1。
// x = 方块光等级 / 15，y = 天空光等级 / 15，范围都是 [0,1]。
SIMPLE_VARYING vec2 vLightmapCoord;

// 视图空间法线，已归一化。光照计算靠它。
SIMPLE_VARYING vec3 vNormalView;

// 视图空间位置。摄像机在原点，看向 -Z。
// 用途：算到摄像机的距离（雾）、算视线方向（高光）、做屏幕空间效果。
SIMPLE_VARYING vec3 vViewPos;

// 未畸变的阴影裁剪坐标。先插值到片元，再除以 w 并施加径向畸变，
// 避免非线性畸变在顶点之间插值时移动接收点。
SIMPLE_VARYING vec4 vShadowClipPos;

// 方块/实体 ID。x = 方块或实体的数字 ID，y = 渲染类型。
// 有了它就能针对特定方块写特效，例如：
//   if (vEntityId.x == 8.0 || vEntityId.x == 9.0) { /* 流水 */ }
SIMPLE_VARYING vec2 vEntityId;

#endif  // LIB_VARYINGS_GLSL


// 方块/物品的贴图图集。天气、粒子等程序也会绑定这张图集。
uniform sampler2D gtexture;

/* ---------------------------------------------------------------------------
 * 实体叠加色
 *   实体受伤会闪红。游戏不通过改变顶点颜色实现，而是提供 entityColor，
 *   它的 a 分量表示叠加强度。
 * ------------------------------------------------------------------------ */
vec4 applyEntityColor(vec4 color) {
    color.rgb = mix(color.rgb, toLinearSpace(entityColor.rgb), entityColor.a);
    return color;
}


/* ---------------------------------------------------------------------------
 * 写出 G-Buffer
 *
 * 参数：
 *   color       已经算完光照（+雾）的线性空间颜色，可以大于 1
 *   normalView  视图空间法线
 *   lightmapCoord 光照贴图坐标（x = 方块光，y = 天空光）
 *   shadow      阴影系数
 *   material    材质标记，用 lib/common.glsl 里的 MAT_* 常量
 *   alpha       输出到 colortex0 的透明度
 * ------------------------------------------------------------------------ */
void writeGBuffers(vec3 color, vec3 normalView, vec2 lightmapCoord,
                   float shadow, float material, float alpha) {
    vec2 lm = prepareLightmapCoord(lightmapCoord);

    // 目标 0：场景颜色。这是后处理真正会去读的那张图。
    fullOut0 = vec4(color, alpha);

    // 目标 1：八面体法线与几何标记；RGBA8 存储保留有限的角度精度。
    fullOut1 = vec4(encodeNormal(normalView), lm.y, material);

    // 目标 2：光照信息。后处理和调试视图都要用。
    fullOut2 = vec4(lm.x, lm.y, shadow, 0.0);
#ifdef WORLD_GPU_BACKEND
    // Attachment 5 holds opaque base radiance until deferred publishes source 4;
    // that pass clears it before its later water-geometry lifetime begins.
    fullOut3 = vec4(color, 1.0);
#else
    // 无材质数据的几何清除后方表面遗留的PBR参数。
    fullOut3 = vec4(0.0);
    // 手部程序不映射该附件，也不生成写入，保证原生场景背景完整保留。
#ifndef FIRST_PERSON_HAND
    fullOut4 = vec4(color, 1.0);
#endif
#endif
}

// 彩色日光传递在缓冲中只保留平均可见度。
void writeGBuffers(vec3 color, vec3 normalView, vec2 lightmapCoord,
                   vec3 shadow, float material, float alpha) {
    writeGBuffers(color, normalView, lightmapCoord, dot(shadow, vec3(1.0 / 3.0)), material, alpha);
}

#endif  // LIB_FRAGMENT_OUTPUT_GLSL

/*
================================================================================
 lib/fog.glsl —— 大气雾 / 水下雾
================================================================================
 为什么需要雾？
   1. 它模拟大气散射：远处的物体因为中间隔着厚厚的空气，对比度下降、
      颜色被天空的颜色"洗掉"。
   2. 它藏住边界：玩家的可视距离是有限的，如果远处物体直接"刷"地消失会
      非常突兀。雾让几何体的尽头自然融入天空。

 本实现不依赖游戏的雾参数，而是自己根据视距（far）算一条曲线，
 这样在游戏里调整渲染距离时表现是一致的、可预期的。
================================================================================
*/
#ifndef LIB_FOG_GLSL
#define LIB_FOG_GLSL







/* 本文件用到的 uniform（全部在 lib/uniforms.glsl 中声明）：
 *   fogColor        游戏提供的地平线雾颜色（vec3）
 *   far             投影远平面距离 = 渲染距离，自定义雾的基准
 *   skyColor        天空颜色，用来给雾染色
 *   isEyeInWater    0 = 空气，1 = 水，2 = 岩浆，3 = 细雪
 */


/* ---------------------------------------------------------------------------
 * 计算给定距离处的雾浓度
 *   返回 0 = 完全清晰，1 = 完全被雾遮蔽
 * ------------------------------------------------------------------------ */
float getFogFactor(float distanceToCamera) {
    // Lava immersion remains dense even when the dimension has a long fog range.
    if (isEyeInWater == 2) {
        return 1.0 - exp(-max(distanceToCamera, 0.0) * 4.0);
    }
    if (isEyeInWater == 1) {
        // 水内光程在 composite 统一处理，避免对岸上几何重复加水雾。
        return 0.0;
    }

#if SIMPLE_DIMENSION != 0
    float density = SIMPLE_DIMENSION == -1 ? NETHER_FOG_DENSITY : END_FOG_DENSITY;
    float extinction = 1.0 - exp(-distanceToCamera * density * FOG_DENSITY);
    float border = smoothstep(far * 0.65, far * 0.98, distanceToCamera);
    return 1.0 - (1.0 - extinction) * (1.0 - border);
#endif
    // 空气中：线性雾。
    // 起点定在 55% 视距 —— 太近会让世界灰蒙蒙的，太远又藏不住边界。
    // FOG_DENSITY 越大，分母越大，雾开始得越早。
    float rain = weatherRainAmount();
    float fogStart = far * mix(0.55, 0.28, rain) / max(FOG_DENSITY, EPSILON);
    float fogEnd   = far * mix(0.98, 0.86, rain) / max(FOG_DENSITY, EPSILON);

    // smoothstep 比 linear 好在两端导数为 0：
    // 雾的"出现"和"饱和"都是渐进的，不会有可见的硬边。
    return smoothstep(fogStart, fogEnd, distanceToCamera);
}


/* ---------------------------------------------------------------------------
 * 计算雾的颜色。
 *   fogColor 是游戏提供的地平线颜色，随日夜、天气及视线方向变化。
 *   远处地形直接趋向这个颜色，才能与天空边缘接上。
 * ------------------------------------------------------------------------ */
vec3 getFogColor() {
    if (isEyeInWater == 1) {
        // 水下：偏青蓝，并且明显压暗，模拟光线被吸收。
        return vec3(0.08, 0.22, 0.35);
    }
    if (isEyeInWater == 2) {
        return vec3(0.60, 0.15, 0.02);  // 岩浆
    }

    // 游戏的 fogColor 就是地平线颜色，并且已随时间、天气更新。
    // 与天空使用同一输入和转换，避免远处地形出现另一种颜色的色带。
    return dimensionFogColor();
}


/* ---------------------------------------------------------------------------
 * 对外的总入口：对颜色应用雾
 *
 * 参数：
 *   color              已经算完光照的颜色
 *   distanceToCamera   该点到摄像机的直线距离（单位：方块）
 *
 * 返回：混合了雾之后的颜色。
 * ------------------------------------------------------------------------ */
vec3 applyFog(vec3 color, float distanceToCamera) {
    float fogFactor = getFogFactor(distanceToCamera);

    // mix(a, b, t) = a * (1-t) + b * t
    // fogFactor 接近 1 时颜色几乎完全变成雾色。
    return mix(color, getFogColor(), fogFactor);
}

// The migrated renderer preserves unfogged opaque radiance for reflections.
// Deferred applies its camera segment once; later particles/translucency retain
// their forward fog. Stage values come from the fixed J9 RenderStage contract.
vec3 applySurfaceFog(vec3 color, float distanceToCamera) {
#ifdef WORLD_GPU_BACKEND
    if (renderStage >= 8 && renderStage <= 15) return color;
#endif
    return applyFog(color, distanceToCamera);
}

#endif  // LIB_FOG_GLSL

/* Surface material lighting shares solar transmission and the companion's
 * existing per-light visibility. Local specular is never gated by solar shadow.
 */
#ifndef LIB_MATERIAL_LIGHTING_GLSL
#define LIB_MATERIAL_LIGHTING_GLSL
/* 通用表面BRDF与反射权重。具体材质参数由资源包LabPBR贴图提供。 */
#ifndef LIB_MATERIALS_GLSL
#define LIB_MATERIALS_GLSL



struct SurfaceMaterial {
    vec3 f0;
    float roughness;
    float metallic;
};

// Smooth mirrors retain the emitter image. Rough surfaces use its integrated
// point-light lobe; the two representations must share one energy budget.
float materialAnalyticEmitterWeight(float roughness) {
    return smoothstep(0.12, 0.18, roughness);
}

vec3 materialFresnel(vec3 f0, float cosine) {
    float edge = pow(1.0 - clamp(cosine, 0.0, 1.0), 5.0);
    return f0 + (1.0 - f0) * edge;
}

// Analytic GGX environment BRDF integral (Lazarov's split-sum fit). A single
// mirror Fresnel factor overestimates grazing reflections on rough dielectrics.
vec3 materialEnvironmentWeight(SurfaceMaterial m, float cosine) {
    vec4 r = m.roughness * vec4(-1.0, -0.0275, -0.572, 0.022)
           + vec4(1.0, 0.0425, 1.04, -0.04);
    float a004 = min(r.x * r.x, exp2(-9.28 * clamp(cosine, 0.0, 1.0))) * r.x + r.y;
    vec2 integrated = vec2(-1.04, 1.04) * a004 + r.zw;
    return clamp(m.f0 * integrated.x + integrated.y, vec3(0.0), vec3(1.0));
}

// A shading normal may reflect below the actual surface at a grazing angle.
// Smith masking removes that impossible lobe; its energy remains in the
// diffuse/transmitted branch instead of reading an unrelated sky direction.
float reflectionGeometricVisibility(float viewCosine, float lightCosine, float roughness) {
    if (viewCosine <= 0.0 || lightCosine <= 0.0) return 0.0;
    float alpha = max(roughness * roughness, 0.001);
    float squared = alpha * alpha;
    float view = 2.0 * viewCosine / (viewCosine
        + sqrt(squared + (1.0 - squared) * viewCosine * viewCosine));
    float light = 2.0 * lightCosine / (lightCosine
        + sqrt(squared + (1.0 - squared) * lightCosine * lightCosine));
    return view * light;
}

// GGX NDF and height-correlated Smith visibility; includes NdotL and Fresnel.
vec3 materialLightSpecular(SurfaceMaterial m, vec3 normal, vec3 view,
                          vec3 light, vec3 radiance) {
    float nl = max(dot(normal, light), 0.0);
    float viewCosine = dot(normal, view);
    if (nl <= 0.0 || viewCosine <= 0.0 || !any(greaterThan(radiance, vec3(0.0)))) {
        return vec3(0.0);
    }
    float nv = max(viewCosine, 0.001);
    vec3 halfway = safeNormalize(view + light, normal);
    float nh = max(dot(normal, halfway), 0.0);
    float vh = max(dot(view, halfway), 0.0);
    float alpha = max(m.roughness * m.roughness, 0.01);
    float a2 = alpha * alpha;
    float denominator = nh * nh * (a2 - 1.0) + 1.0;
    float distribution = a2 / max(PI * denominator * denominator, 0.0000001);
    float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2);
    float gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
    float visibility = 0.5 / max(gv + gl, 0.00001);
    return radiance * materialFresnel(m.f0, vh) * distribution * visibility * nl;
}
// 各向异性GGX。切线来自原生UV方向，提供刷纹方向的宽高光，不采样场景镜像。
vec3 materialAnisotropicSpecular(SurfaceMaterial m, vec3 normal, vec3 tangent, vec3 view,
                                vec3 light, vec3 radiance, float anisotropy) {
    float nv = dot(normal, view);
    float nl = dot(normal, light);
    if (nv <= 0.0 || nl <= 0.0 || !any(greaterThan(radiance, vec3(0.0)))) return vec3(0.0);
    tangent = safeNormalize(tangent - normal * dot(normal, tangent),
        abs(normal.y) < 0.9 ? normalize(cross(normal, vec3(0.0, 1.0, 0.0)))
        : normalize(cross(normal, vec3(1.0, 0.0, 0.0))));
    vec3 bitangent = cross(normal, tangent);
    float alpha = max(m.roughness * m.roughness, 0.01);
    float aspect = sqrt(1.0 - 0.9 * clamp(anisotropy, 0.0, 0.9));
    vec2 axes = vec2(alpha / aspect, alpha * aspect);
    vec3 halfVector = safeNormalize(view + light, normal);
    vec2 h = vec2(dot(halfVector, tangent), dot(halfVector, bitangent)) / axes;
    float nh = max(dot(normal, halfVector), 0.0);
    float denominator = dot(h, h) + nh * nh;
    float distribution = 1.0 / max(PI * axes.x * axes.y * denominator * denominator, 1e-8);
    vec2 v = vec2(dot(view, tangent), dot(view, bitangent)) * axes;
    vec2 l = vec2(dot(light, tangent), dot(light, bitangent)) * axes;
    float lambdaV = sqrt(1.0 + dot(v, v) / max(nv * nv, 1e-8));
    float lambdaL = sqrt(1.0 + dot(l, l) / max(nl * nl, 1e-8));
    float masking = 2.0 / (lambdaV + lambdaL);
    return radiance * materialFresnel(m.f0, max(dot(view, halfVector), 0.0))
        * distribution * masking / max(4.0 * nv, 0.00001);
}
#endif



/* Low-frequency reflected radiance shared by forward shading and SSR.
 * A complete base radiance prevents another metal surface from appearing black
 * in the first reflection bounce, before the screen reflection pass runs.
 */
#ifndef LIB_MATERIAL_ENVIRONMENT_GLSL
#define LIB_MATERIAL_ENVIRONMENT_GLSL



// 离屏反射向下半球时没有天空可见度。粗糙度给地平线一个有限过渡宽度，
// 避免屏幕反射失效后把本应反射地面的方向突然替换成明亮天空。
float reflectionSkyVisibility(vec3 directionWorld, float roughness) {
    float width = max(0.01, roughness * 0.15);
    return smoothstep(-width, width, directionWorld.y);
}

// 倒影里的天空按当地天光可见度衰减。屏幕外的树冠、屋檐无法被屏幕空间光线
// 发现，光照贴图是唯一的线索；曲线比漫反射用的更陡（参考 Sildur 的
// (lm*1.2-0.15)^2），树荫、屋檐下的水面与积水不再反射整片明亮天空。
float reflectionSkyLightWeight(float skyLevel) {
    float weight = clamp(skyLevel * 1.2 - 0.15, 0.0, 1.0);
    return weight * weight;
}

// The native light field supplies low-frequency local radiance when reflected
// geometry is off screen. It never fabricates an unoccluded solar highlight.
vec3 materialAmbientEnvironment(vec3 directionWorld, vec2 lmCoord) {
#if SIMPLE_DIMENSION != 0
    vec3 environment = dimensionAmbient(directionWorld) * AMBIENT_STRENGTH;
#if SIMPLE_DIMENSION == 1
    environment = mix(environment, dimensionBackground(directionWorld) * 1.8,
                      END_ATMOSPHERE * 0.65 * smoothstep(-0.2, 0.5, directionWorld.y));
#endif
    return environment + blockLightRadiance(lmCoord);
#else
    float sky = smoothstep(0.02, 0.95, lightmapLevel(lmCoord.y));
    // 隐藏面的环境回退与可见天空采用同一天气响应，阴雨时不残留晴天蓝色。
    vec3 environment = weatherSkyRadiance(toLinearSpace(skyColor)) * mix(0.15, 0.65, skyDaylight())
                     * mix(0.30, 1.0, directionWorld.y * 0.5 + 0.5);
    return environment * sky + blockLightRadiance(lmCoord);
#endif
}
#endif


vec3 materialPointSpecular(SurfaceMaterial m, vec3 normalView, vec3 viewPosition) {
    if (!hasCompanionLighting()) {
        return vec3(0.0);
    }
    vec3 position = companionPosition(viewPosition, companionOrigin);
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 view = normalize(mat3(gbufferModelViewInverse) * -viewPosition);
#ifndef WORLD_GPU_BACKEND
    float size = companionHeader().z;
    float tint = companionVolumeWeight(position, size, 1.0);
#endif
    int count = int(companionHeader().y + 0.5);
    vec3 sum = vec3(0.0);
    for (int index = 0; index < LOCAL_LIGHT_COUNT; index++) {
        if (index >= count) {
            break;
        }
        vec4 light = companionLight(index, 0);
        vec4 anchor = companionLight(index, 2);
        vec3 ray = light.xyz + anchor.xyz - position;
        float squared = dot(ray, ray);
        float radius = abs(light.w);
        // Unmapped sources wait for their visibility map instead of leaking a
        // sharp highlight through a wall. Their native diffuse light remains.
        if (light.w <= 0.0 || squared >= radius * radius || squared <= 0.0001
            || dot(normal, ray) <= 0.0 || anchor.w <= 0.001) {
            continue;
        }
        vec4 source = companionLight(index, 1);
        float window = max(1.0 - squared * squared / pow(radius, 4.0), 0.0);
#ifdef WORLD_GPU_BACKEND
        WorldPosition receiver = worldPosition(viewToWorld(viewPosition), cameraPosition);
        vec3 transmission = worldPointGlassFilter(colortex6, index, receiver, normal);
#else
        vec3 transmission = mix(vec3(1.0), companionTransmission(index, position), tint);
#endif
        vec3 visibility = companionShadow(index, -ray, radius, normal, transmission);
        vec3 radiance = source.rgb * window * window / (1.0 + squared)
                      * BLOCK_LIGHT_STRENGTH * anchor.w;
        sum += materialLightSpecular(m, normal, view, ray * inversesqrt(squared),
                                     radiance * visibility);
    }
#ifdef WORLD_GPU_BACKEND
    sum *= materialAnalyticEmitterWeight(m.roughness);
#endif
    return sum;
}

vec3 materialDirectSpecular(SurfaceMaterial m, vec3 normal, vec3 viewPosition,
                           vec2 lmCoord, vec3 shadow) {
#if SIMPLE_DIMENSION != 0
    return materialPointSpecular(m, normal, viewPosition);
#endif
    vec3 view = safeNormalize(-viewPosition, normal);
    vec3 solar = materialLightSpecular(m, normal, view, normalize(sunPosition), getSunLightColor())
               + materialLightSpecular(m, normal, view, normalize(moonPosition), getMoonLightColor());
    if (any(greaterThan(solar, vec3(0.0)))) {
        float sky = smoothstep(0.60, 0.96, lightmapLevel(lmCoord.y));
        float cloud = cloudProjectedShadow(viewToAbsoluteWorld(viewPosition),
            normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
        solar *= shadow * sky * cloud;
    }
    return solar + materialPointSpecular(m, normal, viewPosition);
}

#endif

/* 资源包驱动的通用不透明表面。材质贴图保持线性数据，颜色由调用者转为线性空间。 */
#ifndef LIB_PBR_SURFACE_GLSL
#define LIB_PBR_SURFACE_GLSL
/* LabPBR 1.3通用通道解码。不识别方块名称、矿石颜色或特定资源包。
 * specular与normal是线性数据贴图；albedo由调用者预先转为线性颜色。
 */
#ifndef LIB_LABPBR_GLSL
#define LIB_LABPBR_GLSL

struct LabPbrMaterial {
    vec3 albedo;
    vec3 f0;
    float roughness;
    float metallic;
    float emission;
    float porosity;
    float subsurface;
    vec3 tangentNormal;
    float ao;
    float height;
};

// 标准预定义金属的光学常数，不是按游戏方块分类的材质表。
vec3 labPbrConductorF0(int code, vec3 albedo) {
    vec3 n;
    vec3 k;
    if (code == 230) {
        n = vec3(2.9114, 2.9497, 2.5845);
        k = vec3(3.0893, 2.9318, 2.7670);
    }
    else if (code == 231) {
        n = vec3(0.18299, 0.42108, 1.3734);
        k = vec3(3.4242, 2.3459, 1.7704);
    }
    else if (code == 232) {
        n = vec3(1.3456, 0.96521, 0.61722);
        k = vec3(7.4746, 6.3995, 5.3031);
    }
    else if (code == 233) {
        n = vec3(3.1071, 3.1812, 2.3230);
        k = vec3(3.3314, 3.3291, 3.1350);
    }
    else if (code == 234) {
        n = vec3(0.27105, 0.67693, 1.3164);
        k = vec3(3.6092, 2.6248, 2.2921);
    }
    else if (code == 235) {
        n = vec3(1.9100, 1.8300, 1.4400);
        k = vec3(3.5100, 3.4000, 3.1800);
    }
    else if (code == 236) {
        n = vec3(2.3757, 2.0847, 1.8453);
        k = vec3(4.2655, 3.7153, 3.1365);
    }
    else if (code == 237) {
        n = vec3(0.15943, 0.14512, 0.13547);
        k = vec3(3.9291, 3.1900, 2.3808);
    }
    else {
        return clamp(albedo, 0.0, 1.0);
    }
    vec3 numerator = (n - 1.0) * (n - 1.0) + k * k;
    vec3 denominator = (n + 1.0) * (n + 1.0) + k * k;
    return numerator / denominator * clamp(albedo, 0.0, 1.0);
}

LabPbrMaterial decodeLabPbr(vec3 albedo, vec4 specularMap, vec4 normalMap) {
    LabPbrMaterial m;
    m.albedo = max(albedo, vec3(0.0));
    m.roughness = (1.0 - specularMap.r) * (1.0 - specularMap.r);
    int reflectance = int(floor(specularMap.g * 255.0 + 0.5));
    m.metallic = reflectance >= 230 ? 1.0 : 0.0;
    m.f0 = reflectance >= 230 ? labPbrConductorF0(reflectance, m.albedo) : vec3(specularMap.g);
    int blue = int(floor(specularMap.b * 255.0 + 0.5));
    m.porosity = reflectance < 230 && blue <= 64 ? float(blue) / 64.0 : 0.0;
    m.subsurface = reflectance < 230 && blue >= 65 ? float(blue - 65) / 190.0 : 0.0;
    int emissive = int(floor(specularMap.a * 255.0 + 0.5));
    m.emission = emissive < 255 ? float(emissive) / 254.0 : 0.0;
    // XY采用纹理坐标正方向的DirectX约定，切线基的bitangent须指向纹理V增大方向。
    vec2 xy = normalMap.rg * 2.0 - 1.0;
    float z = sqrt(max(1.0 - dot(xy, xy), 0.0));
    m.tangentNormal = normalize(vec3(xy, z));
    m.ao = clamp(normalMap.b, 0.0, 1.0);
    m.height = clamp(normalMap.a, 0.0, 1.0);
    return m;
}
#endif


uniform sampler2D normals;
uniform sampler2D specular;

// 高度数据的POM只在有效原生图集范围内步进。平坦高度直接退出，演示包没有额外成本。
vec2 pbrParallaxUv(vec2 uv, vec3 position, vec3 geometric, vec4 tile) {
#if POM_QUALITY == 0
    return uv;
#else
    vec3 dx = dFdx(position);
    vec3 dy = dFdy(position);
    vec2 du = dFdx(uv);
    vec2 dv = dFdy(uv);
    float determinant = du.x * dv.y - du.y * dv.x;
    vec3 tangent = dx * dv.y - dy * du.y;
    vec3 bitangent = dy * du.x - dx * dv.x;
    if (length(position) > POM_DISTANCE || min(tile.z, tile.w) <= 0.0
        || abs(determinant) < 1e-12 || dot(tangent, tangent) < 1e-16) return uv;
    tangent = normalize(tangent * sign(determinant));
    bitangent = safeNormalize(bitangent * sign(determinant), cross(geometric, tangent));
    vec3 view = safeNormalize(-position, geometric);
    vec3 viewTangent = vec3(dot(view, tangent), dot(view, bitangent), dot(view, geometric));
    if (viewTangent.z <= 0.08) return uv;
    float initialDepth = 1.0 - texture(normals, uv).a;
    if (initialDepth < 0.5 / 255.0) return uv;
#if POM_QUALITY == 1
    const int steps = 8;
#elif POM_QUALITY == 2
    const int steps = 16;
#else
    const int steps = 24;
#endif
    vec2 pixel = 0.5 / vec2(textureSize(normals, 0));
    vec2 minimum = tile.xy - tile.zw + pixel;
    vec2 maximum = tile.xy + tile.zw - pixel;
    vec2 direction = viewTangent.xy / viewTangent.z * tile.zw * 0.5;
    vec2 current = uv;
    vec2 previous = uv;
    float previousDifference = -initialDepth;
    float difference = previousDifference;
    for (int index = 1; index <= steps; index++) {
        float depth = float(index) / float(steps);
        vec2 candidate = uv - direction * depth;
        if (any(lessThan(candidate, minimum)) || any(greaterThan(candidate, maximum))) return current;
        previous = current;
        previousDifference = difference;
        current = candidate;
        difference = depth - (1.0 - texture(normals, current).a);
        if (difference >= 0.0) break;
    }
    float weight = clamp(difference / max(difference - previousDifference, 0.00001), 0.0, 1.0);
    return mix(current, previous, weight);
#endif
}

LabPbrMaterial readPbrSurface(vec3 albedo, vec2 uv) {
    vec4 normalMap = texture(normals, uv);
    if (dot(abs(normalMap), vec4(1.0)) < 0.00001) {
        normalMap = vec4(0.5, 0.5, 1.0, 1.0);
    }
    return decodeLabPbr(albedo, texture(specular, uv), normalMap);
}

// Bitangent指向纹理V增大方向，与LabPBR DirectX绿色通道约定一致。
vec3 pbrSurfaceNormal(vec3 geometric, vec3 position, vec2 uv, vec3 tangentNormal) {
    vec3 dx = dFdx(position);
    vec3 dy = dFdy(position);
    vec2 du = dFdx(uv);
    vec2 dv = dFdy(uv);
    float determinant = du.x * dv.y - du.y * dv.x;
    vec3 tangent = dx * dv.y - dy * du.y;
    vec3 bitangent = dy * du.x - dx * dv.x;
    if (abs(determinant) < 1e-12 || dot(tangent, tangent) < 1e-16) return geometric;
    tangent = normalize(tangent * sign(determinant));
    bitangent = safeNormalize(bitangent * sign(determinant), cross(geometric, tangent));
    return safeNormalize(mat3(tangent, bitangent, geometric) * tangentNormal, geometric);
}

SurfaceMaterial pbrBrdfMaterial(LabPbrMaterial pbr) {
    SurfaceMaterial m;
    m.f0 = pbr.f0;
    // 现有GGX内部将感知粗糙度平方为分布alpha，避免对LabPBR值重复平方。
    m.roughness = max(sqrt(max(pbr.roughness, 0.0)), MATERIAL_GLOSS_ROUGHNESS);
    m.metallic = pbr.metallic;
    return m;
}

vec3 pbrGlossTangent(vec3 normal, vec3 position, vec2 uv) {
    vec3 tangent = dFdx(position) * dFdy(uv).y - dFdy(position) * dFdx(uv).y;
    vec3 fallback = abs(normal.y) < 0.9 ? cross(normal, vec3(0.0, 1.0, 0.0))
        : cross(normal, vec3(1.0, 0.0, 0.0));
    return safeNormalize(tangent - normal * dot(normal, tangent), normalize(fallback));
}

// 现有原生光源候选与逐灯透射缓存提供局部高光，完全不查询反射场景。
vec3 pbrLocalGloss(SurfaceMaterial m, vec3 normalView, vec3 tangentView, vec3 position, float anisotropy) {
#if defined(SIMPLE_VARYING) && (ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0)
    if (!lpvHeaderValid(texelFetch(colortex8, ivec2(0), 0))) return vec3(0.0);
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 tangent = normalize(mat3(gbufferModelViewInverse) * tangentView);
    vec3 view = normalize(mat3(gbufferModelViewInverse) * -position);
    vec3 world = viewToAbsoluteWorld(position) + normal * 0.04;
    vec3 receiver = world - vec3(lpvOrigin(cameraPosition));
    vec3 axis = abs(normal);
    vec3 plane = axis.x >= axis.y && axis.x >= axis.z ? vec3(0.0, 1.0, 1.0)
        : axis.y >= axis.z ? vec3(1.0, 0.0, 1.0) : vec3(1.0, 1.0, 0.0);
    vec3 first = plane.x > 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 second = plane.z > 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    vec3 shifted = receiver - plane * 0.5;
    ivec3 base = ivec3(floor(shifted));
    vec2 fraction = vec2(dot(fract(shifted), first), dot(fract(shifted), second));
    vec3 sum = vec3(0.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            ivec3 cell = base + ivec3(first) * x + ivec3(second) * y;
            if (!lpvInside(cell)) continue;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                * (y == 0 ? 1.0 - fraction.y : fraction.y);
            ivec2 address = lpvAddress(cell);
            vec3 candidates = texelFetch(colortex10, address, 0).rgb;
            for (int entry = 0; entry < 3; entry++) {
                int identity = int(round(candidates[entry])) - 1;
                if (identity < 0) continue;
                ivec3 source = lpvCell(identity);
                uint material = lpvVoxel(source);
                if (lpvKind(material) != LPV_EMITTER) continue;
                vec3 ray = vec3(source) + vec3(0.5, 0.72, 0.5) - receiver;
                float distance = length(ray);
                vec3 colour = lpvColour(material);
                colour *= colour;
#if ENABLE_COLOURED_LIGHTING == 0
                colour = vec3(luma(colour));
#endif
                vec3 transmission = texelFetch(colortex11,
                    address + ivec2(0, entry * textureSize(colortex8, 0).y), 0).rgb;
                vec3 radiance = colour * lpvSourceEnergy(distance, lpvEmission(material)) * transmission;
                sum += materialAnisotropicSpecular(m, normal, tangent, view,
                    ray / max(distance, 0.00001), radiance, anisotropy) * weight;
            }
        }
    }
    vec3 border = vec3(lpvShape()) * 0.5 - abs(world - cameraPosition);
    return sum * smoothstep(1.0, 5.0, min(border.x, min(border.y, border.z)));
#else
    return vec3(0.0);
#endif
}

vec3 pbrDirectGloss(SurfaceMaterial m, vec3 normal, vec3 position, vec2 uv,
                    vec2 lightmap, vec3 shadow) {
    vec3 tangent = pbrGlossTangent(normal, position, uv);
    vec3 view = safeNormalize(-position, normal);
    float anisotropy = MATERIAL_ANISOTROPY * (1.0 - m.roughness);
    vec3 solar = materialAnisotropicSpecular(m, normal, tangent, view,
        normalize(sunPosition), getSunLightColor(), anisotropy)
        + materialAnisotropicSpecular(m, normal, tangent, view,
            normalize(moonPosition), getMoonLightColor(), anisotropy);
    float sky = smoothstep(0.60, 0.96, lightmapLevel(lightmap.y));
    solar *= shadow * sky * cloudProjectedShadow(viewToAbsoluteWorld(position),
        normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
    return solar + pbrLocalGloss(m, normal, tangent, position, anisotropy);
}

vec3 computePbrLighting(LabPbrMaterial pbr, vec3 normal, vec2 lightmap, vec3 shadow,
                       float occlusion, vec3 position, vec2 uv, out vec3 reflectionSource) {
    SurfaceMaterial m = pbrBrdfMaterial(pbr);
    float strength = ENABLE_MATERIAL_REFLECTIONS == 1 ? MATERIAL_REFLECTION_STRENGTH : 0.0;
    vec3 view = safeNormalize(-position, normal);
    bool reflective = max(max(m.f0.r, m.f0.g), m.f0.b) > 0.0001 && strength > 0.0;
    vec3 fraction = vec3(1.0);
    if (reflective) {
        // 偏漫反射的Glossy风格为粗糙金属保留少量基底散射。
        fraction = mix(vec3(1.0), (1.0 - 0.85 * m.metallic)
            * (1.0 - materialFresnel(m.f0, dot(normal, view))), strength);
    }
    vec3 diffuse = computeSurfaceLighting(pbr.albedo * fraction, normal, lightmap, shadow,
        occlusion * pbr.ao, position);
    vec3 environment = vec3(0.0);
    vec3 direct = vec3(0.0);
    if (reflective) {
        vec3 direction = normalize(mat3(gbufferModelViewInverse) * normal);
        environment = materialAmbientEnvironment(direction, lightmap)
            * materialEnvironmentWeight(m, dot(normal, view)) * strength;
        direct = pbrDirectGloss(m, normal, position, uv, lightmap, shadow) * strength;
    }
    vec3 emission = pbr.albedo * pbr.emission * ORE_GLOW_STRENGTH * 4.0;
    reflectionSource = diffuse + environment + emission;
    return reflectionSource + direct;
}
#endif


// OptiFine resolves this ID through the same block.properties mapping.
uniform int blockEntityId;

void main() {
    vec2 materialUv = pbrParallaxUv(vTexCoord, vViewPos,
        safeNormalize(vNormalView, vec3(0.0, 1.0, 0.0)), vPbrTile);
    vec4 albedo = texture(gtexture, materialUv) * vColor;
    albedo.rgb = toLinearSpace(albedo.rgb);
    LabPbrMaterial pbr = readPbrSurface(albedo.rgb, materialUv);
    vec3 pbrNormal = pbrSurfaceNormal(safeNormalize(vNormalView, vec3(0.0, 1.0, 0.0)),
        vViewPos, vTexCoord, pbr.tangentNormal);
    if (albedo.a < alphaTestRef) {
        discard;
    }

    vec3 normalView = pbrNormal;
    vec2 lmCoord = prepareLightmapCoord(vLightmapCoord);
    float viewDistance = length(vViewPos);
    vec3 shadow = getShadowFactor(vShadowClipPos, normalView, viewDistance);
    vec3 reflectionSource;
    vec3 color = computePbrLighting(pbr, normalView, lmCoord, shadow,
        1.0, vViewPos, vTexCoord, reflectionSource);
    color = applySurfaceFog(color, viewDistance);
    writeGBuffers(color, normalView, lmCoord, shadow, MAT_SOLID, albedo.a);
#ifdef WORLD_GPU_BACKEND
    fullOut3 = vec4(reflectionSource, 1.0);
#endif
    fullOut2.a = pbr.metallic;
#ifndef WORLD_GPU_BACKEND
    fullOut3 = vec4(pbr.f0, sqrt(pbr.roughness));
#endif
}

