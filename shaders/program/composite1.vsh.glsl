#define SIMPLE_VARYING out

in vec3 vaPosition;
in vec4 vaColor;
in vec3 vaNormal;
in vec2 vaUV0;
in ivec2 vaUV2;
uniform vec3 modelOffset;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
uniform mat3 normalMatrix;
/* 相机位置决定的低频空气密度在全屏顶点上计算，避免每个体积片元重复读取
 * 相同的两个噪声纹素。各顶点的值一致，透视插值后仍为同一个帧内常量。
 */
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

SIMPLE_VARYING float vAirDensityModulation;

void main() {
    gl_Position = (projectionMatrix * modelViewMatrix * vec4(vaPosition + modelOffset, 1.0));
    vAirDensityModulation = mix(0.98, 1.02, cloudVolumeNoise(cameraPosition / 2048.0).r);
}

