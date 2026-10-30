#define SIMPLE_VARYING in
layout(location=0) out vec4 fullOut0;
layout(location=1) out vec4 fullOut1;
layout(location=2) out vec4 fullOut2;
layout(location=3) out vec4 fullOut3;
layout(location=4) out vec4 fullOut4;
/* 场景合成后的泛光亮部预过滤；首个 alpha 纹素保存每帧一次的太阳可见度。 */
/* RENDERTARGETS: 3 */
/* HDR 泛光：先逐样本提取亮部再降采样，随后执行可分离过滤。
 * 缓冲只使用左下有效视口，所有读取限制到有效纹素中心，避免采到旧天空/体积场。
 * 阈值和峰值限制先于平均，保留细小光源并抑制极亮像素的闪烁。
 */
#ifndef LIB_BLOOM_GLSL
#define LIB_BLOOM_GLSL
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

/* 镜头光学近似：太阳的遮挡感知光晕与轻度径向色差。
 * 光晕亮度只在亮部阶段的首个纹素计算一次，再通过附件 alpha 传递。
 */
#ifndef LIB_LENS_OPTICS_GLSL
#define LIB_LENS_OPTICS_GLSL



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

uniform sampler2D colortex0;
uniform sampler2D depthtex0;

void main() {
    vec2 uv = gl_FragCoord.xy / bloomSize();
    float visibility = 0.0;
    if (gl_FragCoord.x < 1.0 && gl_FragCoord.y < 1.0) {
        visibility = lensSunVisibility(colortex0, depthtex0);
    }
    vec3 bloom = prefilterBloom(colortex0, uv);
    fullOut0 = vec4(bloom, visibility);
}

