#define SIMPLE_VARYING in
layout(location=0) out vec4 fullOut0;
layout(location=1) out vec4 fullOut1;
layout(location=2) out vec4 fullOut2;
layout(location=3) out vec4 fullOut3;
layout(location=4) out vec4 fullOut4;
/* composite2.fsh: sky, water optics and depth-aware volume reconstruction. */
/* RENDERTARGETS: 0 */
const bool colortex6MipmapEnabled = false;
/*
 * Single-scattering volumetric cloud integration with approximate multiple
 * scattering. Main sky clouds render at half resolution; reflections use fewer
 * samples. Empty regions skip lighting and dense rays terminate early. A finite
 * cylindrical horizon bounds grazing rays before any density/noise sampling.
 */
#ifndef LIB_CLOUDS_GLSL
#define LIB_CLOUDS_GLSL

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

/* 表面光照。分别计算日月直射、天空环境光与局部方块光；AO 作用于间接项。
 * 配套数据就绪时接入独立点光阴影和体素 GI，其他情况使用原版光照场。
 */
#ifndef LIB_LIGHTING_GLSL
#define LIB_LIGHTING_GLSL




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

/* Sky lookup, circular celestial bodies and a continuous stellar background. */
#ifndef LIB_SKY_GLSL
#define LIB_SKY_GLSL




uniform sampler2D colortex3;


// Vanilla quads use half-sizes 30 and 20 at distance 100; the visible bright
// cores occupy about one quarter of their gtexture widths. Circular bodies use
// the corresponding apparent core widths, while retaining lunar surface detail.
const float SKY_SUN_RADIUS = 0.075;
const float SKY_MOON_RADIUS = 0.050;

vec3 skyViewDirection(vec2 uv) {
    vec4 ray = gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
    return safeNormalize(mat3(gbufferModelViewInverse) * ray.xyz, vec3(0.0, 1.0, 0.0));
}

vec2 skyLookupCoordinate(vec3 direction) {
    float azimuth = dot(direction.xz, direction.xz) > 0.00000001
        ? atan(direction.z, direction.x) / (2.0 * PI) + 0.5 : 0.5;
    float elevation = 0.5 + 0.5 * sign(direction.y) * sqrt(abs(direction.y));
    return vec2(azimuth, elevation);
}

vec3 skyLookupDirection(vec2 uv) {
    float azimuth = (uv.x - 0.5) * 2.0 * PI;
    float h = uv.y * 2.0 - 1.0;
    float elevation = sign(h) * h * h;
    float horizontal = sqrt(max(1.0 - elevation * elevation, 0.0));
    return vec3(cos(azimuth) * horizontal, elevation, sin(azimuth) * horizontal);
}

// Packed sky/cloud strips are periodic in azimuth, but the whole attachment
// cannot use GL_REPEAT: its other half stores cloud shadows. Only seam pixels
// need two explicit reads; interior pixels keep one hardware-filtered lookup.
vec4 sampleSkyStrip(vec2 coordinate, float strip) {
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0));
    float x = coordinate.x * size.x - 0.5;
    float y = clamp(coordinate.y, 0.0, 1.0) * (size.y - 1.0) + 0.5 + strip * size.y;
    if (x >= 0.0 && x <= size.x - 1.0) {
        return texture(colortex3, vec2(x + 0.5, y) / vec2(viewWidth, viewHeight));
    }
    // 经度只跨过一次边界。显式环绕列号，避免浮点mod在245等宽度上
    // 将mod(width, width)舍入成width，读到天空条带右侧的黑色缓存。
    float lower = floor(x);
    if (lower < 0.0) {
        lower += size.x;
    }
    float upper = lower + 1.0;
    if (upper >= size.x) {
        upper = 0.0;
    }
    vec4 a = texture(colortex3, vec2(lower + 0.5, y) / vec2(viewWidth, viewHeight));
    vec4 b = texture(colortex3, vec2(upper + 0.5, y) / vec2(viewWidth, viewHeight));
    return mix(a, b, fract(x));
}

vec3 skyAtmosphereRadiance(vec3 direction) {
    return sampleSkyStrip(skyLookupCoordinate(direction), 0.0).rgb;
}

// Sky queries run behind depth and water branches, where screen derivatives are
// undefined at silhouettes. Derive a finite pixel cone from projection instead.
float skyPixelAngularWidth(vec3 direction) {
    vec2 planeStep = 2.0 * abs(vec2(gbufferProjectionInverse[0][0],
                                  gbufferProjectionInverse[1][1]))
                   / max(vec2(viewWidth, viewHeight), vec2(1.0));
    vec3 viewRay = normalize(mat3(gbufferModelView) * direction);
    vec2 angularStep = planeStep * abs(viewRay.z)
                     * sqrt(max(vec2(1.0) - viewRay.xy * viewRay.xy, vec2(0.0)));
    return max(length(angularStep), 0.0002);
}

float skyHash(vec2 p) {
    vec3 value = fract(vec3(p.x, p.y, p.x) * 0.1031);
    value += dot(value, value.yzx + 33.33);
    return fract((value.x + value.y) * value.z);
}

// The End's stars resolve at final scene resolution rather than being baked
// into the tiny nebula LUT. A compact 3D kernel has no longitude or pole seam.
vec3 endStellarRadiance(vec3 direction) {
#if SIMPLE_DIMENSION != 1
    return vec3(0.0);
#else
    if (END_ATMOSPHERE <= 0.0) {
        return vec3(0.0);
    }
    vec3 p = direction * 256.0;
    vec3 cell = floor(p);
    float seed = atmosphereHash(cell);
    float radius = clamp(skyPixelAngularWidth(direction) * 256.0 * 0.8, 0.12, 0.45);
    float star = (1.0 - smoothstep(radius * 0.15, radius, length(fract(p) - 0.5))) * step(0.997, seed);
    vec3 tint = mix(vec3(0.55, 0.72, 1.0), vec3(1.0, 0.72, 0.58), atmosphereHash(cell + 19.0));
    return tint * star * (0.20 + 0.60 * atmosphereHash(cell + 47.0)) * END_ATMOSPHERE;
#endif
}

// Stars use spherical cells. Angular derivatives are taken from the ray itself,
// so the longitude seam cannot create a bright vertical line.
vec3 skyStars(vec3 direction) {
#if SIMPLE_DIMENSION == 1
    return endStellarRadiance(direction);
#elif SIMPLE_DIMENSION == -1
    return vec3(0.0);
#endif
    float night = 1.0 - smoothstep(-0.15, -0.03, skySunDirection().y);
    if (night < 0.001 || direction.y < 0.0) {
        return vec3(0.0);
    }
    vec2 coordinate = vec2(atan(direction.z, direction.x) / (2.0 * PI) + 0.5,
                           asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5) * vec2(2048.0, 1024.0);
    vec2 cell = floor(coordinate);
    float seed = skyHash(cell);
    vec2 point = vec2(skyHash(cell + 31.0), skyHash(cell + 79.0));
    float distance = length(fract(coordinate) - point);
    float angularWidth = skyPixelAngularWidth(direction);
    float radius = clamp(angularWidth * 280.0, 0.11, 0.45);
    float star = (1.0 - smoothstep(radius * 0.2, radius, distance)) * step(0.994, seed);
    // The enlarged lunar sphere also hides stars on its unilluminated side.
    float moonRadius = SKY_MOON_RADIUS * CELESTIAL_SIZE;
    float moonDistance = length(direction - skyMoonDirection());
    float moonEdge = min(angularWidth, moonRadius * 0.10);
    float moonCoverage = 1.0 - smoothstep(moonRadius - moonEdge, moonRadius + moonEdge, moonDistance);
    star *= 1.0 - moonCoverage;
    vec3 tint = mix(vec3(0.7, 0.82, 1.0), vec3(1.0, 0.83, 0.66), skyHash(cell + 53.0));
    return tint * star * night * mix(0.25, 1.2, seed) * (1.0 - rainStrength * 0.85);
}

// Orthographic sphere normals generate the lunar terminator. The 0-degree
// longitude at the centre shows the Earth-facing LRO hemisphere.
vec3 lunarDisc(vec3 ray, vec3 direction) {
    vec3 reference = abs(direction.y) > 0.95 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    vec3 right = normalize(cross(reference, direction));
    vec3 up = normalize(cross(direction, right));
    float radius = SKY_MOON_RADIUS * CELESTIAL_SIZE;
    vec2 position = vec2(dot(ray, right), dot(ray, up)) / radius;
    float squared = dot(position, position);
    if (squared > 1.02 || dot(ray, direction) < 0.0 || direction.y < -radius) {
        return vec3(0.0);
    }
    float z = sqrt(max(1.0 - squared, 0.0));
    vec3 normal = vec3(position, z);
    float angle = float(moonPhase) * PI * 0.25;
    vec3 light = vec3(sin(angle), 0.0, cos(angle));
    float incidence = max(dot(normal, light), 0.0);
    float longitude = atan(normal.x, max(normal.z, 0.0001)) / (2.0 * PI) + 0.5;
    float latitude = 0.5 - asin(clamp(normal.y, -1.0, 1.0)) / PI;
    vec2 atlas = vec2((longitude * 511.0 + 0.5) / 1024.0,
                      (768.0 + latitude * 255.0 + 0.5) / 1024.0);
    vec3 albedo = toLinearSpace(texture(noisetex, atlas).rgb);
    float edgeWidth = clamp(skyPixelAngularWidth(ray) / radius, 0.015, 0.10);
    float edge = 1.0 - smoothstep(1.0 - edgeWidth, 1.0 + edgeWidth, sqrt(squared));
    float earthshine = 0.006 * (1.0 - lunarIlluminatedFraction());
    vec3 transmission = atmosphereDirectTransmittance(direction.y);
    float horizon = smoothstep(-0.006, 0.002, ray.y);
    return albedo * (incidence * 2.8 + earthshine) * transmission * edge * horizon
         * clamp(MOONLIGHT_STRENGTH / 0.018, 0.0, 3.0);
}

vec3 skyCelestialRadiance(vec3 ray) {
#if SIMPLE_DIMENSION != 0
    return vec3(0.0);
#endif
    vec3 sun = skySunDirection();
    float radius = SKY_SUN_RADIUS * CELESTIAL_SIZE;
    float distance = length(ray - sun);
    float edgeWidth = min(skyPixelAngularWidth(ray), radius * 0.10);
    float disc = 1.0 - smoothstep(radius - edgeWidth, radius + edgeWidth, distance);
    disc *= smoothstep(-0.006, 0.002, ray.y);
    float limb = sqrt(max(1.0 - distance * distance / (radius * radius), 0.0));
    vec3 solar = vec3(12.0) * disc * mix(0.65, 1.0, limb)
               * atmosphereDirectTransmittance(sun.y) * SUNLIGHT_STRENGTH;
    return solar * mix(1.0, 0.12, weatherRainAmount())
         + lunarDisc(ray, skyMoonDirection()) * mix(1.0, 0.35, weatherRainAmount());
}

vec3 skyRadiance(vec3 direction) {
    return skyAtmosphereRadiance(direction) + skyStars(direction) + skyCelestialRadiance(direction);
}

#endif


vec3 getCloudRayWorld(vec2 uv) {
    return skyViewDirection(uv);
}

bool cloudRayInterval(vec3 origin, vec3 ray, float limit, out float entry, out float exit) {
#if SIMPLE_DIMENSION != 0
    entry = 0.0;
    exit = 0.0;
    return false;
#endif
    vec2 altitude = cloudAltitudeBounds();
    entry = 0.0;
    exit = min(limit, CLOUD_DISTANCE);
    if (abs(ray.y) >= 0.00001) {
        float lower = (altitude.x - origin.y) / ray.y;
        float upper = (altitude.y - origin.y) / ray.y;
        entry = max(min(lower, upper), 0.0);
        exit = min(max(lower, upper), exit);
    } else if (origin.y <= altitude.x || origin.y >= altitude.y) {
        return false;
    }

    // Intersect the camera-centred cylinder, including off-centre origins used
    // by water reflections. Vertical rays retain the full local cloud height.
    vec2 offset = origin.xz - cameraPosition.xz;
    float radius = cloudRenderDistance();
    float horizontal = dot(ray.xz, ray.xz);
    float boundary = dot(offset, offset) - radius * radius;
    if (horizontal > 0.000001) {
        float along = dot(offset, ray.xz);
        float discriminant = along * along - horizontal * boundary;
        if (discriminant <= 0.0) {
            return false;
        }
        float root = sqrt(discriminant);
        entry = max(entry, (-along - root) / horizontal);
        exit = min(exit, (-along + root) / horizontal);
    } else if (boundary >= 0.0) {
        return false;
    }
    return exit > entry;
}

float cloudPhase(float cosine, float g) {
    return (1.0 - g * g) / (4.0 * PI * pow(max(1.0 + g * g - 2.0 * g * cosine, 0.01), 1.5));
}

// Increasing light steps probe both the local shell and the surrounding mass.
float cloudLightOpticalDepth(vec3 position, vec3 direction, int samples) {
    float sum = 0.0;
    float previous = 0.0;
    for (int index = 0; index < 5; index++) {
        if (index >= samples) {
            break;
        }
        float u = float(index + 1) / float(samples);
        float next = CLOUD_THICKNESS * 1.4 * u * u;
        float interval = next - previous;
        sum += cloudDensity(position + direction * (previous + next) * 0.5, false) * interval;
        previous = next;
    }
    return sum * 0.04 * CLOUD_OPACITY;
}

// atmosphere 由调用方提供：deferred 构建环境 LUT 时天空 LUT 尚不可读。
vec4 traceVolumetricCloudsLit(vec3 origin, vec3 ray, float limit, bool reflection, vec3 atmosphere) {
    if (CLOUD_OPACITY <= 0.0 || CLOUD_COVERAGE <= 0.0) {
        return vec4(0.0);
    }
    float entry;
    float exit;
    if (!cloudRayInterval(origin, ray, limit, entry, exit)) {
        return vec4(0.0);
    }
    int samples = CLOUD_QUALITY == 0 ? 24 : (CLOUD_QUALITY == 1 ? 40 : 64);
    int lightSamples = CLOUD_QUALITY == 0 ? 2 : (CLOUD_QUALITY == 1 ? 3 : 5);
    if (reflection) {
        samples = 16;
        lightSamples = 2;
    }
    vec3 lightDirection = skyDaylight() > 0.5 ? skySunDirection() : skyMoonDirection();
    vec3 direct = getSunLightColor() + getMoonLightColor();
    float cosine = dot(ray, lightDirection);
    float phase = cloudPhase(cosine, 0.62) * 0.8 + cloudPhase(cosine, -0.20) * 0.2;
    float day = skyDaylight();
    vec3 ambient = mix(vec3(0.003, 0.0038, 0.005), vec3(0.22, 0.27, 0.33), day);
    ambient *= mix(CLOUD_NIGHT_BRIGHTNESS * (0.2 + 0.8 * lunarIlluminatedFraction()), 1.0, day);
    ambient += vec3(0.060, 0.020, 0.009) * atmosphereTwilight();
    ambient = mix(ambient, vec3(luma(ambient)) * vec3(0.90, 0.95, 1.0) * 0.70,
                  weatherRainAmount());
    float jitter = cloudCellHash(floor(gl_FragCoord.xy));
    vec3 accumulated = vec3(0.0);
    float transmission = 1.0;
    float previous = entry;
    for (int index = 0; index < 64; index++) {
        if (index >= samples || transmission < 0.015) {
            break;
        }
        float u = float(index + 1) / float(samples);
        float next = mix(entry, exit, u * u);
        float stepLength = next - previous;
        vec3 position = origin + ray * mix(previous, next, 0.25 + jitter * 0.5);
        float height;
        float density = cloudDensityWithHeight(position, stepLength < 45.0, height);
        previous = next;
        if (density <= 0.0001) {
            continue;
        }
        float opticalDepth = cloudLightOpticalDepth(position, lightDirection, lightSamples);
        float lightTransmission = exp(-opticalDepth);
        // A second, softer term and a powder approximation preserve luminous
        // shells and soften the contrast inside optically thick cloud masses.
        float multiple = exp(-opticalDepth * 0.28) * 0.22;
        float powder = 1.0 - exp(-density * 8.0);
        vec3 source = ambient * mix(0.40, 1.0, height)
                    + direct * (lightTransmission * phase * 5.0 + multiple) * mix(0.65, 1.0, powder);
        // The outer cloud field loses contrast before its density vanishes,
        // so the finite horizon blends into the same atmosphere as the sky.
        float aerial = exp(-length(position - origin) * mix(0.00016, 0.00035, rainStrength))
                     * cloudHorizonVisibility(position);
        source = mix(atmosphere, source * CLOUD_BRIGHTNESS, aerial);
        float segmentTransmission = exp(-density * stepLength * 0.04 * CLOUD_OPACITY);
        accumulated += transmission * (1.0 - segmentTransmission) * source;
        transmission *= segmentTransmission;
    }
    return vec4(accumulated, 1.0 - transmission);
}

vec4 traceVolumetricCloudsFrom(vec3 origin, vec3 ray, float limit, bool reflection) {
    return traceVolumetricCloudsLit(origin, ray, limit, reflection, skyAtmosphereRadiance(ray));
}

// 反射与水下视线共用的上半球云环境：deferred 每帧以天空 LUT 的映射构建，
// 存放在 colortex3 的 y∈[size.y, 2size.y)，rgb 为预乘辐射，a 为不透明度。
vec4 cloudEnvironment(vec3 direction) {
    if (direction.y <= 0.0 || CLOUD_OPACITY <= 0.0 || CLOUD_COVERAGE <= 0.0) {
        return vec4(0.0);
    }
    vec2 coordinate = skyLookupCoordinate(direction);
    return sampleSkyStrip(coordinate, 1.0);
}

vec4 traceVolumetricClouds(vec3 ray, float limit) {
    if (isEyeInWater == 1) {
        return vec4(0.0);
    }
    return traceVolumetricCloudsFrom(cameraPosition, ray, limit, false);
}

#endif

/* The entire uncovered background shares one atmosphere and celestial model. */
#ifndef LIB_SKY_BACKGROUND_GLSL
#define LIB_SKY_BACKGROUND_GLSL

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


vec3 sceneSkyBackground(vec2 uv) {
    return skyRadiance(skyViewDirection(uv));
}

vec3 fillSkyBackground(vec3 color, vec2 uv, float depth) {
    if (depth >= 0.999999) {
        return sceneSkyBackground(uv);
    }
    return color;
}

// Geometry already contains the original loading-distance fog. Replace only
// its colour contribution, preserving attenuation. After weather blending,
// backgroundTransmission prevents the correction from colouring rain streaks.
vec3 correctSkyFog(vec3 color, vec2 uv, float viewDistance, float backgroundTransmission) {
    if (isEyeInWater != 0) {
        return color;
    }
    float factor = getFogFactor(viewDistance);
    // Nearby surfaces and fully opaque weather have no fog-colour correction.
    // Skip the sky direction, angular lookup and gtexture read for zero weight.
    if (factor <= 0.0 || backgroundTransmission <= 0.0) {
        return color;
    }
    return color + (skyAtmosphereRadiance(skyViewDirection(uv)) - getFogColor())
                 * factor * backgroundTransmission;
}

#endif

#ifndef WORLD_GPU_BACKEND
uniform sampler2D colortex4;
#endif
/*
 * 水面光学：固定水底采样、按光程衰减的透射、局部散射与 Fresnel 倒影。
 * 倒影在不透明深度上进行透视正确的 DDA，深度约束滤波模拟粗糙度。
 * 未命中/离屏时先用阴影贴图找相机看不到的遮挡物，再退回受当地天光限制的
 * 天空与方块云。
 */
#ifndef LIB_WATER_REFLECTION_GLSL
#define LIB_WATER_REFLECTION_GLSL

/* 水面光学与波浪工具。共享 Fresnel、八面体法线编码和连续波浪高度场。
 * 三组正弦分量使用绝对世界坐标保持区块接缝连续，正弦差公式直接求差分法线。
 */
#ifndef LIB_WATER_GLSL
#define LIB_WATER_GLSL





#ifdef WORLD_PACKED_WATER
/* Water geometry and radiance share one RGBA32F attachment. RGB carries three
 * finite 30-bit words; A remains a normal 0/1 blend mask so glass preserves it.
 * Layout: 12+12 normal bits, 32 depth bits, RGB9E5 radiance and a two-bit tag.
 */
#ifndef SIMPLE_WORLD_WATER_PACKET_GLSL
#define SIMPLE_WORLD_WATER_PACKET_GLSL
#ifndef SIMPLE_WORLD_RAW_PACKING_GLSL
#define SIMPLE_WORLD_RAW_PACKING_GLSL

// Each word carries 30 bits in a normalized finite float. Exponents 1..128
// avoid NaNs, infinities and subnormals; RGBA32F stores every bit unchanged.
float worldRawFloat(uint value) {
    uint mantissa = value & 0x007fffffu;
    uint exponent = ((value >> 23u) + 1u) << 23u;
    return uintBitsToFloat(exponent | mantissa);
}

uint worldRawUint(float value) {
    uint word = floatBitsToUint(abs(value));
    uint exponent = ((word >> 23u) & 255u) - 1u;
    return (exponent << 23u) | (word & 0x007fffffu);
}

vec4 worldRawEncode(uvec4 words, bool valid, bool tagged) {
    if (!valid) return vec4(0.0);
    vec4 result = vec4(worldRawFloat(words.x), worldRawFloat(words.y),
        worldRawFloat(words.z), -worldRawFloat(words.w));
    if (tagged) result.x = -result.x;
    return result;
}

bool worldRawValid(vec4 record) {
    if (record.w >= 0.0) return false;
    uvec4 words = floatBitsToUint(abs(record));
    uvec4 exponents = (words >> 23u) & uvec4(255u);
    return all(greaterThanEqual(exponents, uvec4(1u)))
        && all(lessThanEqual(exponents, uvec4(128u)));
}

uvec4 worldRawDecode(vec4 record) {
    return uvec4(worldRawUint(record.x), worldRawUint(record.y),
        worldRawUint(record.z), worldRawUint(record.w));
}
// Read/write fields across the 30-bit word boundary, including full floats.
void worldPutRawField(inout uvec4 words, uint value, int first, int bits) {
    int word = first / 30;
    int shift = first % 30;
    value &= bits == 32 ? 0xffffffffu : (1u << uint(bits)) - 1u;
    words[word] |= (value << uint(shift)) & 0x3fffffffu;
    if (shift + bits > 30) words[word + 1] |= value >> uint(30 - shift);
}

uint worldGetRawField(uvec4 words, int first, int bits) {
    int word = first / 30;
    int shift = first % 30;
    uint value = words[word] >> uint(shift);
    if (shift + bits > 30) value |= words[word + 1] << uint(30 - shift);
    return value & (bits == 32 ? 0xffffffffu : (1u << uint(bits)) - 1u);
}


#endif


struct WaterSurfacePacket {
    vec2 normal;
    float depth;
    vec3 scattering;
    float coverage;
};

uint waterRgb9e5(vec3 radiance) {
    vec3 colour = clamp(radiance, vec3(0.0), vec3(65408.0));
    float peak = max(colour.r, max(colour.g, colour.b));
    int exponent = clamp(int(floor(log2(max(peak, 1e-16)))) + 16, 0, 31);
    float unit = exp2(float(exponent - 24));
    uvec3 mantissa = uvec3(floor(colour / unit + 0.5));
    if (max(mantissa.r, max(mantissa.g, mantissa.b)) > 511u && exponent < 31) {
        exponent++;
        unit *= 2.0;
        mantissa = uvec3(floor(colour / unit + 0.5));
    }
    mantissa = min(mantissa, uvec3(511u));
    return mantissa.r | (mantissa.g << 9u) | (mantissa.b << 18u) | (uint(exponent) << 27u);
}

vec3 waterRgb9e5Value(uint value) {
    uvec3 mantissa = uvec3(value, value >> 9u, value >> 18u) & uvec3(511u);
    return vec3(mantissa) * exp2(float(int(value >> 27u) - 24));
}

vec4 packWaterSurface(vec2 normal, float depth, vec3 scattering) {
    uvec4 words = uvec4(0u);
    uvec2 encoded = uvec2(round(clamp(normal, 0.0, 1.0) * 4095.0));
    worldPutRawField(words, encoded.x, 0, 12);
    worldPutRawField(words, encoded.y, 12, 12);
    worldPutRawField(words, floatBitsToUint(depth), 24, 32);
    worldPutRawField(words, waterRgb9e5(scattering), 56, 32);
    worldPutRawField(words, 2u, 88, 2);
    return vec4(worldRawFloat(words.x), worldRawFloat(words.y), worldRawFloat(words.z), 1.0);
}

WaterSurfacePacket unpackWaterSurface(vec4 packedValue) {
    WaterSurfacePacket result = WaterSurfacePacket(vec2(0.5), 0.0, vec3(0.0), 0.0);
    if (packedValue.a < 0.5) return result;
    uvec4 words = uvec4(worldRawUint(packedValue.x), worldRawUint(packedValue.y),
        worldRawUint(packedValue.z), 0u);
    if (worldGetRawField(words, 88, 2) != 2u) return result;
    result.normal = vec2(worldGetRawField(words, 0, 12), worldGetRawField(words, 12, 12)) / 4095.0;
    result.depth = uintBitsToFloat(worldGetRawField(words, 24, 32));
    result.scattering = waterRgb9e5Value(worldGetRawField(words, 56, 32));
    result.coverage = 1.0;
    return result;
}

WaterSurfacePacket readWaterPacket(sampler2D geometry, vec2 uv) {
    ivec2 size = textureSize(geometry, 0);
    vec2 coordinate = uv * vec2(size) - 0.5;
    ivec2 nearest = clamp(ivec2(floor(uv * vec2(size))), ivec2(0), size - 1);
    if (all(lessThan(abs(coordinate - round(coordinate)), vec2(0.0002)))) {
        return unpackWaterSurface(texelFetch(geometry, nearest, 0));
    }
    ivec2 first = ivec2(floor(coordinate));
    vec2 fraction = fract(coordinate);
    WaterSurfacePacket sum = WaterSurfacePacket(vec2(0.0), 0.0, vec3(0.0), 0.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            ivec2 pixel = clamp(first + ivec2(x, y), ivec2(0), size - 1);
            WaterSurfacePacket value = unpackWaterSurface(texelFetch(geometry, pixel, 0));
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                * (y == 0 ? 1.0 - fraction.y : fraction.y) * value.coverage;
            sum.normal += value.normal * weight;
            sum.depth += value.depth * weight;
            sum.scattering += value.scattering * weight;
            sum.coverage += weight;
        }
    }
    if (sum.coverage < 0.5) return WaterSurfacePacket(vec2(0.5), 0.0, vec3(0.0), 0.0);
    sum.normal /= sum.coverage;
    sum.depth /= sum.coverage;
    sum.scattering /= sum.coverage;
    return sum;
}
#endif

#endif


// block.properties 将水映射到此 ID，避免玻璃也产生波浪。
const float WATER_BLOCK_ID = 100.0;
const float WATER_IOR = 1.333;
uniform sampler2D colortex13;

// 无偏振介质 Fresnel。eta 是入射侧/透射侧折射率，临界角外返回全反射。
float waterDielectricFresnel(float cosine, float eta) {
    float c = clamp(cosine, 0.0, 1.0);
    float discriminant = 1.0 - eta * eta * (1.0 - c * c);
    if (discriminant <= 0.0) {
        return 1.0;
    }
    float transmitted = sqrt(discriminant);
    float parallel = (eta * c - transmitted) / max(eta * c + transmitted, EPSILON);
    float perpendicular = (c - eta * transmitted) / max(c + eta * transmitted, EPSILON);
    return clamp((parallel * parallel + perpendicular * perpendicular) * 0.5, 0.0, 1.0);
}

// 重载、离水、传送及缺帧时拒绝历史；竖直移动按相机位移预测真实水深。
bool validWaterMediumHistory(vec4 history) {
    float previousFrame = mod(float(frameCounter) + 720719.0, 720720.0);
    return abs(history.w - 4183.0) < 0.5 && abs(history.z - previousFrame) < 0.5
        && length(cameraPosition - previousCameraPosition) < 16.0;
}

// 水面几何与参数各自以 alpha=1 标记有效片元，玻璃以 alpha=0 保留这些数据。
// 返回既有逻辑使用的布局：八面体法线 RG、天空可见度 B、线性视图深度 A。
vec4 readWaterSurface(sampler2D geometry, sampler2D parameters, vec2 uv) {
#ifdef WORLD_PACKED_WATER
    WaterSurfacePacket packedSurface = readWaterPacket(geometry, uv);
    if (packedSurface.coverage < 0.5) return vec4(0.0);
    return vec4(packedSurface.normal, texture(parameters, uv).r, packedSurface.depth);
#else
    vec4 surface = texture(geometry, uv);
    if (surface.a < 0.5) {
        return vec4(0.0);
    }
    float sky = texture(parameters, uv).r;
    return vec4(surface.rg, sky, surface.b);
#endif
}

vec3 readWaterScattering(sampler2D geometry, sampler2D scattering, vec2 uv) {
#ifdef WORLD_PACKED_WATER
    return readWaterPacket(geometry, uv).scattering;
#else
    return texture(scattering, uv).rgb;
#endif
}

// 从透明水面附件的线性深度恢复位置，供水面合成与水深估计共用。
vec3 waterSurfacePosition(vec2 uv, float linearDepth) {
    vec4 ray = gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, 0.0, 1.0);
    return ray.xyz * (linearDepth / max(-ray.z, EPSILON));
}

// 空气到水的折射率约为 1.333，法向入射的反射率约为 2%。
float waterFresnel(float cosine) {
    return 0.0204 + 0.9796 * pow(1.0 - clamp(cosine, 0.0, 1.0), 5.0);
}

// 八面体编码保留完整法线方向，包括负 Z；两个通道足以用于反射。
vec2 waterSign(vec2 value) {
    return vec2(value.x >= 0.0 ? 1.0 : -1.0, value.y >= 0.0 ? 1.0 : -1.0);
}

vec2 encodeWaterNormal(vec3 normal) {
    normal /= abs(normal.x) + abs(normal.y) + abs(normal.z);
    vec2 encoded = normal.xy;
    if (normal.z < 0.0) {
        encoded = (1.0 - abs(encoded.yx)) * waterSign(encoded);
    }
    return encoded * 0.5 + 0.5;
}

vec3 decodeWaterNormal(vec2 encoded) {
    vec2 value = encoded * 2.0 - 1.0;
    vec3 normal = vec3(value, 1.0 - abs(value.x) - abs(value.y));
    if (normal.z < 0.0) {
        normal.xy = (1.0 - abs(normal.yx)) * waterSign(normal.xy);
    }
    return normalize(normal);
}

// 优先读取原生水柱深度与水面天光，避免深水亮度随相机朝向变化。
// 缺少新元数据时退回屏幕探针，仍只接受水平水面并平均水深。
vec2 estimateWaterMedium(sampler2D surfaces, sampler2D parameters) {
    if (hasCompanionLighting()) {
#ifdef WORLD_GPU_BACKEND
        vec4 medium = worldCameraWaterMedium();
#else
        vec4 medium = texture(companionAtlas, vec2(0.5, 7.5) / companionAtlasSize());
#endif
        if (abs(medium.w - 1573.0) < 0.5 && medium.z > 0.5) {
            return medium.xy;
        }
    }
    float depthSum = 0.0;
    float count = 0.0;
    for (int x = 0; x < 3; x++) {
        for (int y = 0; y < 3; y++) {
            vec2 uv = vec2(0.15 + float(x) * 0.35, 0.60 + float(y) * 0.18);
            vec4 surface = readWaterSurface(surfaces, parameters, uv);
            if (surface.a > 0.001) {
                vec3 normal = mat3(gbufferModelViewInverse) * decodeWaterNormal(surface.xy);
                vec3 relative = (gbufferModelViewInverse
                    * vec4(waterSurfacePosition(uv, surface.a), 1.0)).xyz;
                float weight = smoothstep(0.02, 0.25, relative.y)
                    * smoothstep(0.65, 0.90, abs(normal.y));
                depthSum += max(relative.y, 0.0) * weight;
                count += weight;
            }
        }
    }
    float skylight = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
    vec4 history = texture(colortex13, vec2(0.5));
    bool valid = validWaterMediumHistory(history);
    float predicted = valid ? max(history.x + previousCameraPosition.y - cameraPosition.y, 0.0)
        : (1.0 - skylight) * 15.0;
    // 水面退出视野时沿用水位预测，不在“屏幕探针/天光估计”之间跳换。
    float observed = count > 0.001 ? depthSum / count : predicted;
    float depth = mix(predicted, observed, valid ? 1.0 - exp(-min(frameTime, 0.1) * 6.0) : 1.0);
    // 屏幕上某一块水面的天光不再决定整帧雾色，遮挡过渡只跟随相机天光。
    float sky = valid ? mix(history.y, skylight, 1.0 - exp(-min(frameTime, 0.1) * 3.5)) : skylight;
    return vec2(clamp(depth, 0.0, 64.0), sky);
}

// 波浪参数。想让水面更平静就调小这些数。
#define WAVE_AMPLITUDE 0.075   // 波高（方块）
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
 * 做法：利用正弦差公式直接计算原有中心差分的斜率。
 *   sin(p + d) - sin(p - d) = 2 cos(p) sin(d)。
 *   每个波只需一次 cos，结果与原先四次高度采样相同。
 *   法线 = normalize(vec3(-dh/dx, 1, -dh/dz))
 *
 *   eps 取 0.25 个方块：太小会让波浪显得过于尖锐（而且可能采到同一个顶点
 *   导致全零向量），太大又会让相邻顶点的法线差异被抹平。
 */
vec3 getWaterWaveNormal(vec2 worldXZ, float time) {
    const float eps = 0.25;
    float t = time * WAVE_SPEED;
    vec2 waveA = vec2(0.9, 0.4) * WAVE_SCALE;
    vec2 waveB = vec2(-0.6, 1.0) * WAVE_SCALE * 1.3;
    vec2 waveC = vec2(0.3, -1.0) * WAVE_SCALE * 2.1;
    vec2 slope = cos(dot(worldXZ, waveA) + t * 1.7)
               * 0.50 * sin(waveA * eps) / eps;
    slope += cos(dot(worldXZ, waveB) - t * 1.1)
           * 0.35 * sin(waveB * eps) / eps;
    slope += cos(dot(worldXZ, waveC) + t * 2.3)
           * 0.15 * sin(waveC * eps) / eps;
    slope *= WAVE_AMPLITUDE;

    // 世界空间的 y 轴朝上，所以基础法线是 (0,1,0)。
    // 斜率越大，法线越偏离竖直方向。（取负号是链式法则的结果）
    return normalize(vec3(-slope.x, 1.0, -slope.y));
}

#endif  // LIB_WATER_GLSL

/* Screen-space intersections against the immutable opaque depth layer.
 * Each sample is classified against the visible depth: in front, inside the
 * assumed object thickness, or deep behind. Entering the thickness band from
 * either side is refined by bisection. A local depth plane must then intersect
 * the ray inside its own pixel, so continuous surfaces give exact hits.
 * Reconstructing geometry from depth also works during translucent rendering,
 * when the normal attachment no longer describes this opaque depth layer.
 *
 * 深度缓冲只记录物体正面，不知道物体有多厚。参考 BSL 的厚度判断：
 *   - 光线进入可见表面后方一个物体厚度以内，视为打中该物体。
 *     连续表面用局部平面求出精确交点；轮廓像素和单像素的叶片、
 *     叶隙里露出的山体没有可用的切线，直接命中该像素（打进物体侧面）。
 *   - 光线从前景后方很深处穿过时不算命中；它之后可能从叶隙后方
 *     直接进入山体的厚度范围（深→内），同样会被细化并命中。
 *     旧版只检测前→后的穿越，透过树叶的倒影因此露出天空。
 *   - 前景挡住原本在光线后方的背景时，记住背景深度；光线在前景后方
 *     到达这个深度即命中背景（树叶、树干后方的山体），取背景的真实颜色。
 *   - 水面倒影裁掉水面以下的像素：河床既不会被打中，也不挡住光线。
 * 未命中时不猜测遮挡物：屏幕空间无法区分“在几何体后方”与“被几何体挡住”。
 * 旧版用压暗的轮廓颜色代替天空，倒影里出现大量细黑边。
 * 相机看不到的遮挡由 reflection_occlusion.glsl 用阴影贴图判断。
 * 命中距离没有远距离淡出：远处的山和树林也应出现在倒影里，而不是渐变成天空。
 */
#ifndef LIB_SCREEN_REFLECTION_GLSL
#define LIB_SCREEN_REFLECTION_GLSL


// Sample pixel centres explicitly; interpolated depth invents silhouette geometry.
vec2 reflectionPixelUv(vec2 uv) {
    vec2 size = vec2(viewWidth, viewHeight);
    return (clamp(floor(uv * size), vec2(0.0), size - 1.0) + 0.5) / size;
}

float reflectionSceneDepth(sampler2D depths, vec2 uv) {
    vec2 pixelUv = reflectionPixelUv(uv);
    float depth = texture(depths, pixelUv).r;
    return depth < 0.999999 ? -screenToView(pixelUv, depth).z : far;
}

// 光线可达的可见深度。clipPlane（视图空间，xyz 为法线）以下的像素视为空：
// 水面倒影的光线在水面之上，透过水面看到的河床既不会被打中，也不挡住任何
// 水面以上的东西。旧版先命中河床像素、再判定“在水下”而整条光线作废，
// 岸边与水中前景的倒影因此露出天空。xyz 为 0 时不裁剪。
float reflectionTraceDepth(sampler2D depths, vec2 uv, vec4 clipPlane) {
    vec2 pixelUv = reflectionPixelUv(uv);
    float depth = texture(depths, pixelUv).r;
    if (depth >= 0.999999) {
        return far;
    }
    vec3 point = screenToView(pixelUv, depth);
    return dot(clipPlane.xyz, point) + clipPlane.w < 0.0 ? far : -point.z;
}

// 天空邻居不能充当平面的切线：把它推到极远处，让另一侧被选为较近的邻居。
vec3 reflectionNeighbour(sampler2D depths, vec2 uv) {
    float depth = texture(depths, uv).r;
    if (depth >= 0.999999) {
        return vec3(0.0, 0.0, -1.0e6);
    }
    return screenToView(uv, depth);
}

// The nearer depth neighbour on each axis avoids spanning a silhouette with
// the reconstructed plane. Its normal faces the camera, as visible geometry does.
// pixelKind describes the first pixel when validation fails: 0 has a plane,
// 1 has no continuous neighbour on some axis (a one-pixel leaf, or background
// seen through a one-pixel gap), 2 is a grazing pixel spanning a large depth.
bool reflectionSurfaceHit(sampler2D depths, vec3 origin, vec3 direction,
                          float minDistance, float range, inout vec2 uv,
                          out float distanceToHit, out int pixelKind) {
    vec2 initialUv = uv;
    pixelKind = 0;
    distanceToHit = 0.0;
    for (int attempt = 0; attempt < 3; attempt++) {
        vec2 pixelUv = reflectionPixelUv(uv);
        vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
        float depth = texture(depths, pixelUv).r;
        if (depth >= 0.999999) {
            return false;
        }
        vec3 centre = screenToView(pixelUv, depth);
        vec3 left = reflectionNeighbour(depths, pixelUv - vec2(texel.x, 0.0));
        vec3 right = reflectionNeighbour(depths, pixelUv + vec2(texel.x, 0.0));
        vec3 down = reflectionNeighbour(depths, pixelUv - vec2(0.0, texel.y));
        vec3 up = reflectionNeighbour(depths, pixelUv + vec2(0.0, texel.y));
        // A one-pixel leaf or fence can have background on both sides. Those
        // neighbours provide no surface tangent; fitting them invents a sloped face.
        float continuity = max(0.05, -centre.z * 0.02);
        bool isolatedX = min(abs(left.z - centre.z), abs(right.z - centre.z)) > continuity
                      && (centre.z - left.z) * (right.z - centre.z) <= 0.0;
        bool isolatedY = min(abs(down.z - centre.z), abs(up.z - centre.z)) > continuity
                      && (centre.z - down.z) * (up.z - centre.z) <= 0.0;
        // A continuous grazing plane can change depth rapidly, but its two
        // one-sided slopes keep the same sign and must remain eligible for hits.
        if (isolatedX || isolatedY) {
            pixelKind = attempt == 0 ? 1 : pixelKind;
            return false;
        }
        vec3 dx = abs(left.z - centre.z) < abs(right.z - centre.z) ? centre - left : right - centre;
        vec3 dy = abs(down.z - centre.z) < abs(up.z - centre.z) ? centre - down : up - centre;
        // 地平线附近一个像素可以覆盖几十格深度，这样的像素既说不清平面在哪里，
        // 也会让几乎平行于平面的光线被误判为命中（倒影里出现一条亮线）。
        if (max(abs(dx.z), abs(dy.z)) > -centre.z * 0.3) {
            pixelKind = attempt == 0 ? 2 : pixelKind;
            return false;
        }
        vec3 normal = safeNormalize(cross(dx, dy), vec3(0.0, 0.0, 1.0));
        normal *= dot(normal, -centre) >= 0.0 ? 1.0 : -1.0;
        float facing = dot(normal, direction);
        if (facing >= -0.001) {
            return false;
        }
        distanceToHit = dot(normal, centre - origin) / facing;
        if (distanceToHit <= minDistance || distanceToHit > range) {
            return false;
        }
        vec4 clip = gbufferProjection * vec4(origin + direction * distanceToHit, 1.0);
        vec2 hitUv = clip.xy / clip.w * 0.5 + 0.5;
        vec2 error = abs(hitUv - pixelUv) / texel;
        if (clip.w <= 0.0) {
            return false;
        }
        uv = hitUv;
        if (max(error.x, error.y) <= 0.55) {
            return true;
        }
        // Raster depth is a staircase. Its first crossing can be in the pixel
        // next to the real plane hit; revalidate that pixel instead of dropping
        // alternating phases of an otherwise continuous reflected surface.
        vec2 relocation = abs(hitUv - initialUv) / texel;
        if (max(relocation.x, relocation.y) > 2.0) {
            return false;
        }
    }
    return false;
}

// 物体被当作实心体的厚度（方块）。远处深度与步进误差更大，容差随距离增加。
float reflectionThickness(float depth) {
    return max(0.5, depth * 0.025);
}

// 只在屏幕边缘淡出：靠近边缘的命中随时会随视角移出屏幕，提前过渡到环境。
float reflectionConfidence(vec2 uv) {
    vec2 edge = min(uv, 1.0 - uv);
    return smoothstep(0.0, 0.03, min(edge.x, edge.y));
}

// 一个轴上的轮廓：某侧邻居明显更远，且不在另一侧邻居延伸出的平面上。
// 平面上的 1/深度 随屏幕坐标线性变化；地平线附近的地面相邻两行可差几十格，
// 但三个像素的 1/深度 仍共线，它是连续平面而不是物体侧面。
bool reflectionSilhouetteAxis(float minus, float centre, float plus) {
    float gap = centre + max(0.25, centre * 0.03);
    float inverseCentre = 1.0 / centre;
    float slopeMinus = inverseCentre - 1.0 / minus;
    float slopePlus = 1.0 / plus - inverseCentre;
    float tolerance = 0.5 * min(abs(slopeMinus), abs(slopePlus)) + inverseCentre * 0.005;
    return max(minus, plus) > gap && abs(slopePlus - slopeMinus) > tolerance;
}

// 至少一侧邻居明显更远（含天空）：这个像素位于物体轮廓上。
bool reflectionSilhouette(sampler2D depths, vec2 pixelUv, float depth, vec4 clipPlane) {
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    return reflectionSilhouetteAxis(
               reflectionTraceDepth(depths, pixelUv - vec2(texel.x, 0.0), clipPlane), depth,
               reflectionTraceDepth(depths, pixelUv + vec2(texel.x, 0.0), clipPlane))
        || reflectionSilhouetteAxis(
               reflectionTraceDepth(depths, pixelUv - vec2(0.0, texel.y), clipPlane), depth,
               reflectionTraceDepth(depths, pixelUv + vec2(0.0, texel.y), clipPlane));
}

// Q=position/w and k=1/w interpolate linearly along the projected ray.
// The result stores hit UV, distance along the ray and edge confidence.
// minDistance rejects hits closer than this along the ray: an opaque receiver
// needs a small margin against itself, water has no receiver in the depth buffer.
// thinHit marks a pixel hit whose visible face is not the face struck.
vec4 traceScreenReflection(sampler2D depths, vec3 origin, vec3 direction,
                           float minDistance, float range, int steps, vec4 clipPlane,
                           out bool thinHit) {
    thinHit = false;
    if (direction.z > 0.001) {
        range = min(range, (-near * 1.05 - origin.z) / direction.z);
    }
    if (range <= minDistance) {
        return vec4(0.0);
    }
    vec4 startClip = gbufferProjection * vec4(origin, 1.0);
    vec4 endClip = gbufferProjection * vec4(origin + direction * range, 1.0);
    float k0 = 1.0 / startClip.w;
    float k1 = 1.0 / endClip.w;
    vec3 q0 = origin * k0;
    vec3 q1 = (origin + direction * range) * k1;
    vec2 uv0 = startClip.xy * k0 * 0.5 + 0.5;
    vec2 uv1 = endClip.xy * k1 * 0.5 + 0.5;
    // Spend the step budget on the visible segment, including camera-facing
    // rays whose untrimmed near-plane projection lies far outside the screen.
    vec2 delta = uv1 - uv0;
    vec2 boundary = mix(vec2(0.002), vec2(0.998), step(vec2(0.0), delta));
    vec2 exitT = (boundary - uv0) / (delta + mix(vec2(-EPSILON), vec2(EPSILON), step(vec2(0.0), delta)));
    float endT = clamp(min(exitT.x, exitT.y), 0.0, 1.0);
    float extent = max(abs(delta.x * viewWidth), abs(delta.y * viewHeight)) * endT;
    if (extent < 1.0) {
        return vec4(0.0);
    }
    vec2 pixelStep = normalize(delta * vec2(viewWidth, viewHeight)) / vec2(viewWidth, viewHeight);
    float stepT = endT * max(1.0 / float(steps), 1.0 / extent);
    float previousT = 0.0;
    float previousRay = -origin.z;
    // 0：在可见表面前方；1：在物体厚度以内；2：在可见表面后方很深处。
    // 起点（接收面本身）若已在厚度以内，不会触发命中。
    float startDepth = reflectionTraceDepth(depths, uv0, clipPlane);
    float startDelta = previousRay - startDepth;
    int previousState = startDelta < 0.0 ? 0 : (startDelta <= reflectionThickness(startDepth) ? 1 : 2);
    float previousScene = startDepth;
    vec2 previousUv = uv0;
    // 光线从可见背景前方转到前景物体后方时，记住被挡住的背景深度和像素。
    float coveredDepth = far;
    vec2 coveredUv = uv0;
    for (int index = 0; index < 64; index++) {
        if (index >= steps) {
            break;
        }
        float t = min(float(index + 1) * stepT, endT);
        vec2 uv = mix(uv0, uv1, t);
        float rayDepth = -mix(q0.z, q1.z, t) / mix(k0, k1, t);
        float sceneDepth = reflectionTraceDepth(depths, uv, clipPlane);
        float difference = rayDepth - sceneDepth;
        // 一步之内光线深度的变化也计入容差，粗步长不会从薄物体旁跳过。
        float band = reflectionThickness(sceneDepth) + abs(rayDepth - previousRay);
        int state = difference < 0.0 ? 0 : (difference <= band ? 1 : 2);
        // 前景（树干、树叶、栏杆）在这一步挡住了原本在光线后方的背景：
        // 背景多半在它后面继续延伸，记住背景深度和遮挡边缘处的背景像素。
        // 背景重新露出且光线仍在它前方时，前景已经过去，清除记录。
        // 起点像素是接收面本身（掠射时是它身后的同一平面），不能当作背景。
        if (index > 0 && previousState == 0 && previousScene > sceneDepth + band) {
            coveredDepth = previousScene;
            coveredUv = previousUv;
        } else if (state == 0) {
            if (sceneDepth > coveredDepth - reflectionThickness(coveredDepth)) {
                coveredDepth = far;
            }
        }
        // 前→后：陡峭的连续表面在一步之内深度变化很大，光线可能直接从前方
        // 跳到很深处，同样要找出穿越点；之后由厚度和平面验证区分
        // “打中表面”与“从细小前景后方经过”。
        bool entering = previousState == 0;
        if ((state == 1 && previousState != 1) || (state == 2 && entering)) {
            float low = previousT;
            float high = t;
            for (int iteration = 0; iteration < 10; iteration++) {
                float mid = (low + high) * 0.5;
                float lowRay = -mix(q0.z, q1.z, low) / mix(k0, k1, low);
                float highRay = -mix(q0.z, q1.z, high) / mix(k0, k1, high);
                float rayZ = -mix(q0.z, q1.z, mid) / mix(k0, k1, mid);
                float testDepth = reflectionTraceDepth(depths, mix(uv0, uv1, mid), clipPlane);
                float testDelta = rayZ - testDepth;
                if (testDelta >= 0.0 && (entering
                    || testDelta <= reflectionThickness(testDepth) + abs(highRay - lowRay))) {
                    high = mid;
                } else {
                    low = mid;
                }
            }
            vec2 hitUv = mix(uv0, uv1, high);
            vec3 crossing = mix(q0, q1, high) / mix(k0, k1, high);
            float front = reflectionTraceDepth(depths, hitUv, clipPlane);
            float gap = -crossing.z - front;
            if (gap >= -0.01 && gap <= reflectionThickness(front) && front < far) {
                vec2 surfaceUv = hitUv;
                float distanceToHit;
                int pixelKind;
                if (reflectionSurfaceHit(depths, origin, direction, minDistance, range,
                                         surfaceUv, distanceToHit, pixelKind)) {
                    return vec4(surfaceUv, distanceToHit, reflectionConfidence(surfaceUv));
                }
                // 没有平面可用的像素（轮廓、单像素叶片、叶隙中的山体）：
                // 光线在其表面后方一个厚度以内，视为打进这个物体。
                // 连续表面上的验证失败（掠射时的自身反射）不做处理。
                vec2 pixelUv = reflectionPixelUv(hitUv);
                distanceToHit = length(crossing - origin);
                if ((pixelKind == 1 || (pixelKind == 0 && reflectionSilhouette(depths, pixelUv, front, clipPlane)))
                    && distanceToHit > minDistance && distanceToHit <= range) {
                    // 沿光线再往前一个像素：若前景迅速变近，说明这是掠射平面
                    // （例如地平线附近的地面，一个像素覆盖几十格深度），
                    // 光线其实从它上方掠过，不能当作打进物体侧面。
                    float beyond = reflectionTraceDepth(depths, hitUv + pixelStep, clipPlane);
                    if (front - beyond <= reflectionThickness(front)) {
                        thinHit = true;
                        return vec4(pixelUv, distanceToHit, reflectionConfidence(pixelUv));
                    }
                }
                // 光线从正面进入了一个连续表面却没有命中（掠射的自身平面）：
                // 它没有从细小前景后方经过，近处的同一平面不是遮挡背景的前景。
                coveredDepth = far;
            }
        }
        // 光线在前景后方到达被挡背景的深度：视为打中背景。透过叶隙看到的山体、
        // 树干后的地面因此出现在倒影里，而不是天空；颜色是真实背景，不再压暗。
        float behind = rayDepth - coveredDepth;
        if (state != 0 && coveredDepth < far && behind >= 0.0
            && behind <= reflectionThickness(coveredDepth) + abs(rayDepth - previousRay)) {
            vec2 pixelUv = reflectionPixelUv(coveredUv);
            float coveredDistance = length(mix(q0, q1, t) / mix(k0, k1, t) - origin);
            if (coveredDistance > minDistance) {
                thinHit = true;
                return vec4(pixelUv, coveredDistance, reflectionConfidence(pixelUv));
            }
        }
        previousT = t;
        previousRay = rayDepth;
        previousState = state;
        previousScene = sceneDepth;
        previousUv = uv;
        if (t >= endT) {
            break;
        }
    }
    return vec4(0.0);
}

vec4 traceScreenReflection(sampler2D depths, vec3 origin, vec3 direction,
                           float minDistance, float range, int steps, out bool thinHit) {
    return traceScreenReflection(depths, origin, direction, minDistance, range, steps,
                                 vec4(0.0), thinHit);
}

vec4 traceScreenReflection(sampler2D depths, vec3 origin, vec3 direction,
                           float range, int steps) {
    bool thinHit;
    return traceScreenReflection(depths, origin, direction, 0.05, range, steps, thinHit);
}

#endif

/* Adaptive screen reflection inspired by the refinement strategy used in BSL,
 * Complementary and Sildur. A candidate is refined by shortening the travelled
 * segment; thin alpha-tested surfaces need no unreliable depth-plane normal.
 */
#ifndef LIB_SCREEN_REFLECTION_ADAPTIVE_GLSL
#define LIB_SCREEN_REFLECTION_ADAPTIVE_GLSL



struct ScreenReflectionHit {
    vec2 uv;
    float distance;
    float coverage;
    float confidence;
    bool refined;
};

ScreenReflectionHit screenReflectionHit(vec4 hit, float confidence, bool refined) {
    return ScreenReflectionHit(hit.xy, hit.z, hit.a, confidence, refined);
}

// Continuous opaque depth can reject a back-facing plane. A ray travelling up
// from water cannot hit the top of a sand step from underneath. Cutout texels
// and silhouettes with no reliable tangent retain their raster coverage.
bool reflectionSurfaceFacesRay(sampler2D scene, sampler2D depths, vec2 uv, vec3 direction) {
    if (texture(scene, uv).a > 2.5) return true;
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 centre = screenToView(uv, texture(depths, uv).r);
    vec3 left = reflectionNeighbour(depths, clamp(uv - vec2(texel.x, 0.0), texel * 0.5, 1.0 - texel * 0.5));
    vec3 right = reflectionNeighbour(depths, clamp(uv + vec2(texel.x, 0.0), texel * 0.5, 1.0 - texel * 0.5));
    vec3 down = reflectionNeighbour(depths, clamp(uv - vec2(0.0, texel.y), texel * 0.5, 1.0 - texel * 0.5));
    vec3 up = reflectionNeighbour(depths, clamp(uv + vec2(0.0, texel.y), texel * 0.5, 1.0 - texel * 0.5));
    vec3 dx = abs(left.z - centre.z) < abs(right.z - centre.z) ? centre - left : right - centre;
    vec3 dy = abs(down.z - centre.z) < abs(up.z - centre.z) ? centre - down : up - centre;
    vec3 plane = cross(dx, dy);
    float magnitude = length(plane);
    float continuity = max(0.04, -centre.z * 0.015);
    if (magnitude <= 1e-10 || abs(dx.z) > continuity || abs(dy.z) > continuity) return true;
    plane /= magnitude;
    plane *= dot(plane, -centre) >= 0.0 ? 1.0 : -1.0;
    return dot(plane, direction) < 0.001;
}

ScreenReflectionHit traceAdaptiveReflectionDetailed(sampler2D scene, sampler2D depths, vec3 origin, vec3 direction,
    float minimum, float maximum, int budget, vec4 clipPlane) {
    float stride = max(0.005, length(origin) / max(viewHeight, 1.0) * 0.25);
    float distance = minimum;
    int refinements = 0;
    vec4 closest = vec4(0.0);
    float closestError = 1e20;
    vec4 candidate = vec4(0.0);
    float candidateStride = 1e20;
    vec4 background = vec4(0.0);
    float backgroundError = 1e20;
    vec2 foregroundUv = vec2(0.0);
    float foregroundDepth = 0.0;
    float foregroundError = 1e20;
    for (int iteration = 0; iteration < 96; iteration++) {
        if (iteration >= budget || distance > maximum) break;
        float previous = distance;
        distance += stride;
        vec3 point = origin + direction * distance;
        vec4 clip = gbufferProjection * vec4(point, 1.0);
        if (clip.w <= near) break;
        vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
        // A clamped off-screen sample repeats the border across the mirror.
        // Leave the visible depth domain so the caller can use its environment.
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;
        vec2 size = vec2(viewWidth, viewHeight);
        vec2 unclampedUv = uv;
        uv = clamp(uv, 0.5 / size, 1.0 - 0.5 / size);
        vec2 pixel = (floor(uv * size) + 0.5) / size;
        float depth = texture(depths, pixel).r;
        if (depth < 0.999999) {
            vec3 surface = screenToView(pixel, depth);
            if (dot(clipPlane.xyz, surface) + clipPlane.w >= 0.0) {
                float error = length(point - surface);
                float cone = max(0.003, -surface.z * 2.0
                    * abs(gbufferProjectionInverse[1][1]) / max(viewHeight, 1.0));
                float along = dot(surface - origin, direction);
                float perpendicular = length(surface - origin - direction * along);
                if (along > minimum && along < maximum && perpendicular < cone * 1.5
                    && perpendicular < closestError && reflectionSurfaceFacesRay(scene, depths, pixel, direction)) {
                    closestError = perpendicular;
                    closest = vec4(pixel, along, 1.0);
                }
                // Retain a nearby opaque backing surface as a lower-confidence
                // reconstruction. This uses an actual frame pixel and depth;
                // it does not invent a hidden plane from an earlier sample.
                float flags = texture(scene, pixel).a;
                float edgeAllowance = length((unclampedUv - uv) * size)
                    * cone / 2.0;
                float normalizedError = perpendicular / max(cone, edgeAllowance);
                if (flags > 2.5 && along > minimum && along < maximum
                    && normalizedError < foregroundError) {
                    foregroundError = normalizedError;
                    foregroundUv = pixel;
                    foregroundDepth = -surface.z;
                }
                if (flags > 0.5 && flags < 1.5 && along > minimum && along < maximum
                    && normalizedError < 16.0 && normalizedError < backgroundError) {
                    background = vec4(pixel, along, 1.0);
                    backgroundError = normalizedError;
                }
                if (error < max(stride * 1.25, cone)
                    && reflectionSurfaceFacesRay(scene, depths, pixel, direction)) {
                    // A finite quality budget may end during refinement. Keep
                    // the last actual surface reached by the shrinking segment;
                    // exhausting iterations does not turn that surface into sky.
                    if (along > minimum && along < maximum && stride < candidateStride) {
                        candidate = vec4(pixel, along, 1.0);
                        candidateStride = stride;
                    }
                    if (refinements >= 4 || stride < cone * 0.25) {
                        vec2 edge = min(uv, vec2(1.0) - uv);
                        float confidence = smoothstep(0.0, 0.02, min(edge.x, edge.y));
                        return screenReflectionHit(vec4(pixel, max(along, minimum), 1.0), confidence, true);
                    }
                    refinements++;
                    distance = previous;
                    stride *= 0.22;
                    continue;
                }
            }
        }
        stride *= 1.8;
    }
    // A geometrically supported pixel remains usable when the final step ran
    // out of budget. It does not become sky merely because its neighbours are
    // leaves, a thin fence, or background at another depth.
    if (closest.a > 0.0) return screenReflectionHit(closest, 0.7, false);
    if (candidate.a > 0.0) return screenReflectionHit(candidate, 0.4, false);
    if (foregroundDepth > 0.0 && background.a > 0.0) {
        return screenReflectionHit(background, 1.0 / (1.0 + backgroundError), false);
    }
    // WORLD_BACKGROUND_RECONSTRUCTION
    return screenReflectionHit(vec4(0.0), 0.0, false);
}

// Existing consumers use geometric coverage for colour composition. Confidence
// is reserved for validation/history and must not reveal sky inside a known hit.
vec4 traceAdaptiveReflection(sampler2D scene, sampler2D depths, vec3 origin, vec3 direction,
    float minimum, float maximum, int budget, vec4 clipPlane) {
    ScreenReflectionHit hit = traceAdaptiveReflectionDetailed(scene, depths, origin,
        direction, minimum, maximum, budget, clipPlane);
    return vec4(hit.uv, hit.distance, hit.coverage);
}
#endif

/* Opaque reflection radiance is straight linear HDR at mip zero. Filtering
 * must validate each texel before reading colour; a filtered colour lookup can
 * already contain sky/foreground pixels that a later depth test cannot remove.
 */
#ifndef LIB_REFLECTION_SOURCE_GLSL
#define LIB_REFLECTION_SOURCE_GLSL

#ifdef WORLD_GPU_BACKEND
ivec2 reflectionSourceTexel(sampler2D field, vec2 uv) {
    vec2 size = vec2(textureSize(field, 0));
    return ivec2(clamp(floor(uv * size), vec2(0.0), size - 1.0));
}
#define reflectionSourceRead(field, uv) texelFetch(field, reflectionSourceTexel(field, uv), 0)
#else
// The GLSL 120 path has no colour mip chain; exact centres still read level 0.
#define reflectionSourceRead(field, uv) texture(field, uv)
#endif

vec2 reflectionSourcePixel(vec2 uv) {
    vec2 size = vec2(viewWidth, viewHeight);
    return clamp(floor(uv * size), vec2(0.0), size - 1.0);
}

vec3 reflectionSourcePoint(sampler2D depths, vec2 pixel) {
    vec2 uv = (pixel + 0.5) / vec2(viewWidth, viewHeight);
    float depth = reflectionSourceRead(depths, uv).r;
    return depth < 0.999999 ? screenToView(uv, depth) : vec3(0.0, 0.0, -1e6);
}

// Only neighbours belonging to the hit plane participate. At one-pixel leaves
// or silhouettes there is no reliable plane, so the exact hit texel is retained.
vec3 reflectionSourceRadiance(sampler2D scene, sampler2D depths, vec2 uv) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 centrePixel = reflectionSourcePixel(uv);
    vec2 centreUv = (centrePixel + 0.5) / size;
    vec3 centre = reflectionSourcePoint(depths, centrePixel);
    vec3 left = reflectionSourcePoint(depths, max(centrePixel - vec2(1.0, 0.0), vec2(0.0)));
    vec3 right = reflectionSourcePoint(depths, min(centrePixel + vec2(1.0, 0.0), size - 1.0));
    vec3 down = reflectionSourcePoint(depths, max(centrePixel - vec2(0.0, 1.0), vec2(0.0)));
    vec3 up = reflectionSourcePoint(depths, min(centrePixel + vec2(0.0, 1.0), size - 1.0));
    vec3 dx = abs(left.z - centre.z) < abs(right.z - centre.z) ? centre - left : right - centre;
    vec3 dy = abs(down.z - centre.z) < abs(up.z - centre.z) ? centre - down : up - centre;
    vec3 plane = cross(dx, dy);
    float scale = length(plane);
    float continuity = max(0.04, -centre.z * 0.015);
    bool valid = scale > 1e-10 && abs(dx.z) < continuity && abs(dy.z) < continuity;
    if (!valid) return reflectionSourceRead(scene, centreUv).rgb;
    plane /= scale;
    float tolerance = max(0.002, min(length(dx), length(dy)) * 0.12);
    vec2 pixel = uv * size - 0.5;
    vec2 first = floor(pixel);
    vec2 fraction = fract(pixel);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(first + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            vec2 sampleUv = (cell + 0.5) / size;
            float depth = reflectionSourceRead(depths, sampleUv).r;
            if (depth >= 0.999999) continue;
            vec3 point = screenToView(sampleUv, depth);
            if (abs(dot(plane, point - centre)) > tolerance) continue;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y);
            // RGB is not premultiplied by opaque alpha. Dividing it by coverage
            // brightens cutout edges; mip levels also mix unrelated geometry.
            sum += reflectionSourceRead(scene, sampleUv).rgb * weight;
            total += weight;
        }
    }
    return total > 0.00001 ? sum / total : reflectionSourceRead(scene, centreUv).rgb;
}
// Reconstruct radiance on the hit surface. The image footprint is not a set of
// reflected directions: a sky texel beside a wall does not prove the reflection
// ray missed the wall. Reject that texel without reducing the confirmed hit's
// coverage. Roughness integration traces directions separately.
vec4 reflectionSourceFiltered(sampler2D scene, sampler2D depths, vec2 uv,
    float hitDepth, float distance, float roughness) {
    float radius = roughness * roughness * min(viewWidth, viewHeight) * 0.03
        * clamp(distance / max(hitDepth, 0.01), 0.0, 2.0);
    vec3 centre = reflectionSourceRadiance(scene, depths, uv);
    if (radius < 0.25) return vec4(centre, 1.0);
    vec3 sum = centre;
    float covered = 1.0;
    vec2 size = vec2(viewWidth, viewHeight);
    for (int x = -1; x <= 1; x += 2) {
        for (int y = -1; y <= 1; y += 2) {
            vec2 tap = clamp(uv + vec2(float(x), float(y)) * radius / size,
                0.5 / size, 1.0 - 0.5 / size);
            vec2 pixel = (reflectionSourcePixel(tap) + 0.5) / size;
            float depth = reflectionSourceRead(depths, pixel).r;
            if (depth >= 0.999999) continue;
            float z = -screenToView(pixel, depth).z;
            if (abs(z - hitDepth) > max(0.10, hitDepth * 0.06)) continue;
            sum += reflectionSourceRead(scene, pixel).rgb;
            covered += 1.0;
        }
    }
    return vec4(sum / covered, 1.0);
}

#endif

/* A reflection source is surface radiance, without camera fog. Apply only the
 * reflected air segment here; the receiving surface applies its own segment.
 */
#ifndef LIB_REFLECTION_MEDIUM_GLSL
#define LIB_REFLECTION_MEDIUM_GLSL



vec3 reflectionAirMedium(vec3 radiance, float distance, vec3 viewDirection) {
#ifdef WORLD_GPU_BACKEND
    if (isEyeInWater != 0) return radiance;
    float opacity = getFogFactor(distance);
    if (opacity <= 0.0) return radiance;
    vec3 colour = getFogColor();
#if SIMPLE_DIMENSION == 0
    vec3 direction = normalize(mat3(gbufferModelViewInverse) * viewDirection);
    colour = skyAtmosphereRadiance(direction);
#endif
    return mix(radiance, colour, opacity);
#else
    return radiance;
#endif
}
#endif



/* 水面局部光照与 GGX 高光；只供片元阶段使用。 */
#ifndef LIB_WATER_LIGHTING_GLSL
#define LIB_WATER_LIGHTING_GLSL




/* 共享 PCSS 近似：遮挡搜索决定半影宽度，接收面斜率补偿避免掠射光的阴影脱离。 */
#ifndef LIB_SHADOW_FILTER_GLSL
#define LIB_SHADOW_FILTER_GLSL



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


// shadowtex1 不含半透明水体，避免水面把自身遮成黑色。

// Minecraft 光照坐标的端点是 8/256 与 248/256，对应等级 0 与 15。
float waterSkyLevel(float lightmapY) {
    return clamp((lightmapY - 0.03125) / 0.9375, 0.0, 1.0);
}

float waterSkyVisibility(float lightmapY) {
    return smoothstep(0.02, 0.95, waterSkyLevel(lightmapY));
}

// 水色直接定义为线性散射反照率，避免较暗的显示色再经 gamma 压缩后接近黑色。
// 群系只保留少量色相差异；实际辐射仍由当地环境光和直射光决定。
// 真实水体的散射很弱，看到的颜色主要来自倒影：这里采用偏暗、饱和度较低的青蓝，
// 让晴天显出天空的蓝、雨天显灰、夜晚趋黑，而不是始终是一层浓重的蓝色。
vec3 waterScatteringAlbedo(vec3 biomeTint) {
    vec3 biome = toLinearSpace(biomeTint);
    float maximum = max(max(biome.r, biome.g), max(biome.b, EPSILON));
    vec3 hue = biome / maximum;
    vec3 palette = mix(vec3(0.012, 0.045, 0.055), vec3(0.026, 0.090, 0.105),
                       WATER_COLOR_LIGHTNESS);
    return palette * mix(vec3(1.0), hue, 0.15);
}

// 保留距离淡出与接收面斜率补偿，水体仅接收不透明物体投出的阴影。
float waterOpaqueShadow(vec4 shadowClipPos, vec3 normalView, float viewDistance) {
    return sampleSoftDirectionalShadow(shadowtex1, shadowClipPos, normalView, viewDistance);
}


// 水体底色以间接光为主，日月直射主要由独立高光表现，避免散射水色过亮。
// 当地光照贴图包含方块光，封闭水域仍由当地照明决定亮度。
vec3 waterDiffuse(vec3 albedo, vec3 normalView, vec2 lmCoord,
                  float directVisibility, vec3 viewPosition) {
    vec3 ambient = surfaceAmbientAt(lmCoord, 1.0, normalView, viewPosition);
#if SIMPLE_DIMENSION != 0
    return albedo * ambient;
#endif
    float sunCosine = max(dot(normalView, normalize(sunPosition)), 0.0);
    float moonCosine = max(dot(normalView, normalize(moonPosition)), 0.0);
    vec3 direct = getSunLightColor() * sunCosine + getMoonLightColor() * moonCosine;
    return albedo * (ambient + direct * directVisibility * 0.12);
}

// GGX 分布与 Smith 遮蔽近似，太阳/月亮都使用水的 Fresnel，避免任意白色亮斑。
vec3 waterLightSpecular(vec3 normal, vec3 view, vec3 light, vec3 radiance, float roughness) {
    float nl = max(dot(normal, light), 0.0);
    // 日月中的无贡献光源，以及朝向背离光源的波面，无需执行 GGX 的后续运算。
    if (nl <= 0.0 || !any(greaterThan(radiance, vec3(0.0)))) {
        return vec3(0.0);
    }
    vec3 halfVector = safeNormalize(view + light, normal);
    float nv = max(dot(normal, view), 0.001);
    float nh = max(dot(normal, halfVector), 0.0);
    float vh = max(dot(view, halfVector), 0.0);
    float alpha = max(roughness * roughness, 0.006);
    float alphaSquared = alpha * alpha;
    float denominator = nh * nh * (alphaSquared - 1.0) + 1.0;
    float distribution = alphaSquared / (PI * denominator * denominator);
    float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    float geometryV = nv / (nv * (1.0 - k) + k);
    float geometryL = nl / (nl * (1.0 - k) + k);
    float brdf = distribution * geometryV * geometryL * waterFresnel(vh) / max(4.0 * nv * nl, 0.001);
    return radiance * brdf * nl;
}

vec3 waterDirectSpecular(vec3 normalView, vec3 viewPosition, float roughness) {
#if SIMPLE_DIMENSION != 0
    return vec3(0.0);
#endif
    vec3 view = safeNormalize(-viewPosition, normalView);
    return waterLightSpecular(normalView, view, normalize(sunPosition), getSunLightColor(), roughness)
         + waterLightSpecular(normalView, view, normalize(moonPosition), getMoonLightColor(), roughness);
}

#endif

/* Water absorption and illuminated in-scattering shared by surface/underwater optics. */
#ifndef LIB_WATER_VOLUME_GLSL
#define LIB_WATER_VOLUME_GLSL





vec3 waterExtinctionCoefficient() {
    vec3 absorption = mix(vec3(0.12, 0.045, 0.022), vec3(0.045, 0.02, 0.01), WATER_COLOR_LIGHTNESS);
    return absorption * WATER_ABSORPTION + vec3(WATER_TURBIDITY);
}

// 水下表面与光柱共用同一消光模型，红色比蓝色更快衰减。
// 各向同性散射单独保留，最低能见度只放宽雾遮蔽，不恢复已吸收的颜色。
float underwaterScatteringCoefficient() {
    return (WATER_TURBIDITY + 0.018) * UNDERWATER_DENSITY * FOG_DENSITY;
}

vec3 underwaterExtinctionCoefficient() {
    vec3 absorption = (waterExtinctionCoefficient() - vec3(WATER_TURBIDITY))
                    * vec3(1.8, 1.1, 0.95) * UNDERWATER_DENSITY * FOG_DENSITY;
    return absorption + vec3(underwaterScatteringCoefficient());
}

// 水下先形成低亮度的蓝色基调，再叠加距离雾；近处不再保持空气中的白亮色。
// 方块光占优时减弱冷色过滤，让火把、岩浆等局部光源保留自身色相。
vec3 underwaterSceneTint(float eyeDepth, float surfaceSky) {
    float skyLevel = clamp(surfaceSky, 0.0, 1.0);
    float localLevel = clamp(float(eyeBrightnessSmooth.x) / 240.0, 0.0, 1.0);
    float skyWeight = smoothstep(0.02, 0.45, skyLevel) * (1.0 - localLevel * 0.75);
    float depth = 1.0 - exp(-min(eyeDepth, 32.0) * 0.12 * UNDERWATER_DEPTH_DIMMING);
    vec3 tint = mix(vec3(0.12, 0.38, 0.62), vec3(0.06, 0.27, 0.49), depth);
    tint *= mix(0.65, 1.0, getDayFactor());
    return mix(vec3(0.72, 0.84, 0.94), tint, skyWeight);
}

// Local light is independent of daylight; no fixed blue glow is added to dark caves.
vec3 underwaterScatterColor(float eyeDepth, float surfaceSky) {
    float cameraSky = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
    float skyLevel = clamp(surfaceSky, 0.0, 1.0);
    float localLevel = clamp(float(eyeBrightnessSmooth.x) / 240.0, 0.0, 1.0);
    vec3 sky = toLinearSpace(skyColor);
    float skyMaximum = max(max(sky.r, sky.g), max(sky.b, 0.001));
    vec3 skyTint = sky / skyMaximum;
    float depthFade = 0.45 + 0.55 * exp(-eyeDepth * 0.04 * UNDERWATER_DEPTH_DIMMING);
    // 深水中用有界曝光补偿保留蓝色雾光；其能量仍由水面天光限制。
    // 封闭水域的 surfaceSky 和 cameraSky 均低，不会因补偿获得室外照明。
    float adaptation = mix(1.0, 3.0, 1.0 - smoothstep(0.05, 0.50, cameraSky));
    vec3 daylight = vec3(0.001, 0.10, 0.20) * mix(vec3(1.0), skyTint, 0.25) * skyLevel * skyLevel
                  * (0.06 + 0.94 * getDayFactor()) * depthFade * adaptation;
    vec3 local = vec3(0.13, 0.065, 0.022) * pow(localLevel, 3.0) * BLOCK_LIGHT_STRENGTH;
    return daylight + local + vec3(0.004, 0.025, 0.045) * UNDERWATER_MIN_VISIBILITY;
}

vec3 applyUnderwaterVolume(vec3 radiance, float pathLength, vec3 sceneTint, vec3 scatterColor) {
    float distance = clamp(pathLength, 0.0, 256.0);
    vec3 transmittance = exp(-underwaterExtinctionCoefficient() * distance);
    // A limited near-field floor keeps navigation possible at any immersion depth.
    // It fades away by 18 blocks, so distant shallow geometry remains obscured.
    float nearVisibility = 1.0 - smoothstep(9.0, 18.0, pathLength);
    float minimumTransmission = min(UNDERWATER_MIN_VISIBILITY * 4.0, 0.75) * nearVisibility;
    float scatteringTransmission = exp(-underwaterScatteringCoefficient() * distance);
    transmittance *= max(scatteringTransmission, minimumTransmission)
                   / max(scatteringTransmission, EPSILON);
    return radiance * sceneTint * transmittance + scatterColor * (1.0 - transmittance);
}

#endif

/* 柔和聚光与水下日照工具。变形胞元模拟聚光纹理，太阳折射方向决定投影；
 * 仅查询现有的不透明阴影图，不生成光子、光照贴图或额外场景数据。
 */
#ifndef LIB_WATER_EFFECTS_GLSL
#define LIB_WATER_EFFECTS_GLSL




vec3 waterSunDirection() {
    return normalize(refract(-getSunDirWorld(), vec3(0.0, 1.0, 0.0), 1.0 / 1.333));
}

// 两层低频噪声使用三次插值平滑，形成宽而不规则的明暗起伏。
// 不绘制线框或窄亮边；聚光与体积光柱分别调制，避免水底出现发光条纹。
float waterFocusPattern(vec2 position) {
    vec2 drift = frameTimeCounter * vec2(0.055, -0.037);
    vec2 rotated = vec2(position.x * 0.83 + position.y * 0.56,
                        position.y * 0.83 - position.x * 0.56);
    float broad = cloudWeatherNoise(rotated * 0.42 + drift);
    float fine = cloudWeatherNoise(rotated * 0.86 - drift * 0.7 + vec2(13.7, 29.1));
    return broad * 0.68 + fine * 0.32;
}

// 聚光查询水面入射点以避免水底自阴影；散射查询体积点以保留沿途遮挡。
float waterSunVisibility(vec3 worldPosition, float softness) {
#if ENABLE_SHADOWS == 0
    return 1.0;
#else
    vec4 projected = shadowProjection * shadowModelView
                   * vec4(worldPosition - cameraPosition, 1.0);
    vec3 clip = projected.xyz / max(projected.w, EPSILON);
    vec3 coordinate = distortShadow(clip) * 0.5 + 0.5;
    if (any(lessThan(coordinate, vec3(0.0))) || any(greaterThan(coordinate, vec3(1.0)))) {
        return 0.0;
    }
    float receiver = coordinate.z - 0.00015;
    if (softness <= 0.0) {
        return filteredShadowVisibility(shadowtex1, coordinate.xy, receiver);
    }
    // 宽核的每个采样仍执行真实纹素上的双线性比较，不重新划分阴影网格。
    float distortion = (1.0 - SHADOW_MAP_BIAS) + length(clip.xy) * SHADOW_MAP_BIAS;
    float radius = softness * 0.5 * abs(shadowProjection[0][0]) / max(distortion, 0.05);
    radius = min(radius, 3.0 / shadowTextureResolution());
    float visibility = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 offset = (vec2(float(x), float(y)) * 2.0 - 1.0) * radius;
            visibility += filteredShadowVisibility(shadowtex1, coordinate.xy + offset, receiver);
        }
    }
    return visibility * 0.25;
#endif
}

// 深度几何的导数保留水底与池壁的朝向，无需增加不透明法线附件。
vec3 waterReceiverNormal(vec3 worldPosition) {
    vec3 normal = safeNormalize(cross(dFdx(worldPosition), dFdy(worldPosition)), vec3(0.0, 1.0, 0.0));
    if (dot(normal, cameraPosition - worldPosition) < 0.0) {
        normal = -normal;
    }
    return normal;
}

// 流动胞元的间隙形成不规则聚光网；高斯横截面保留纹理，又避免硬亮边。
float waterCausticRidges(vec2 position, float width) {
    vec2 cell = floor(position);
    vec2 local = fract(position);
    float nearest = 8.0;
    float second = 8.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 neighbour = vec2(float(x), float(y));
            vec2 seed = vec2(cloudCellHash(cell + neighbour),
                             cloudCellHash(cell + neighbour + 37.2));
            vec2 point = 0.5 + 0.28 * sin(seed * TAU + frameTimeCounter * 0.45);
            vec2 delta = neighbour + point - local;
            float distance = dot(delta, delta);
            if (distance < nearest) {
                second = nearest;
                nearest = distance;
            } else {
                second = min(second, distance);
            }
        }
    }
    float gap = (sqrt(second) - sqrt(nearest)) * 0.5;
    return exp(-0.5 * square(gap / width));
}

// 两个尺度叠加保留聚光网细节；只扩散亮边，不模糊整个图案或水底颜色。
float waterCausticPattern(vec2 position, float depth, float footprint) {
    float time = frameTimeCounter * 0.35;
    vec2 warp = sin(vec2(dot(position, vec2(0.85, 0.52)),
                         dot(position, vec2(-0.46, 0.97))) + vec2(time, -time)) * 0.35;
    vec2 p = position + warp + getWaterWaveNormal(position, frameTimeCounter).xz * 1.4;
    float width = 0.055 + min(depth, 12.0) * 0.003 + WATER_TURBIDITY * 0.15;
    float filteredWidth = sqrt(width * width + footprint * footprint);
    float broad = waterCausticRidges(p * 1.1, filteredWidth * 1.1);
    float fine = waterCausticRidges(p * 1.76 + vec2(23.7, 9.2), filteredWidth * 1.76);
    float focus = (broad * 0.75 + fine * 0.25) * 2.8 - 0.45;
    return focus * width / filteredWidth * (1.0 - smoothstep(0.15, 0.50, footprint));
}

float waterCausticGain(vec3 worldPosition, vec3 normalWorld, float waterHeight, float skyVisibility) {
    float depth = waterHeight - worldPosition.y;
    vec3 direction = waterSunDirection();
    vec3 entry = worldPosition - direction * (max(depth, 0.0) / max(-direction.y, 0.2));
    // 导数在提前退出之前计算，保持相邻片元对的足迹有效；昂贵的胞元纹理
    // 等确认日照、朝向、深度与入射遮挡有效后再生成。
    float footprint = length(fwidth(entry.xz)) * 0.5;
    float sunlight = luma(getSunLightColor()) * skyVisibility * (1.0 - rainStrength * 0.8);
    if (WATER_CAUSTICS_STRENGTH <= 0.0 || depth <= 0.02 || depth >= 32.0 || sunlight <= 0.001) {
        return 1.0;
    }
    float facing = max(dot(normalWorld, -direction), 0.0);
    if (facing <= 0.0 || footprint >= 0.50) {
        return 1.0;
    }
    float depthFade = exp(-depth * 0.10) * (1.0 - smoothstep(18.0, 32.0, depth));
    float visibility = waterSunVisibility(entry, 0.0);
    if (visibility <= 0.0) {
        return 1.0;
    }
    float focus = waterCausticPattern(entry.xz, depth, footprint);
    return max(1.0 + focus * facing * depthFade * sunlight * visibility
               * WATER_CAUSTICS_STRENGTH * 0.90, 0.65);
}

// 水面限制水内光程；临界角窗口在最终界面合成中单独处理。
float underwaterVisiblePath(vec2 uv, float opaqueDepth, float surfaceDepth, float eyeDepth) {
    vec3 geometry = screenToView(uv, opaqueDepth < 0.999999 ? opaqueDepth : 0.5);
    float distance = opaqueDepth < 0.999999 ? length(geometry) : far;
    if (surfaceDepth > 0.001 && (opaqueDepth >= 0.999999 || -geometry.z > surfaceDepth + 0.015)) {
        vec3 surfacePosition = waterSurfacePosition(uv, surfaceDepth);
        if (viewToAbsoluteWorld(surfacePosition).y > cameraPosition.y + 0.02) {
            return min(distance, length(surfacePosition));
        }
    }
    vec3 ray = normalize(mat3(gbufferModelViewInverse) * screenToView(uv, 0.5));
    if (ray.y > 0.001 && eyeDepth > 0.02) {
        distance = min(distance, eyeDepth / ray.y);
    }
    return distance;
}

// 双瓣 Henyey–Greenstein 相函数：窄前向瓣提供朝阳的亮度，宽瓣保留侧向雾光。
// 光束的边界由真实阴影积分形成，不能在太阳周围绘制人为的角向条纹。
float waterScatteringPhase(float cosine) {
    float c = clamp(cosine, -1.0, 1.0);
    float narrow = (1.0 - 0.76 * 0.76)
        / pow(max(1.0 + 0.76 * 0.76 - 2.0 * 0.76 * c, 0.001), 1.5);
    float broad = (1.0 - 0.42 * 0.42)
        / pow(max(1.0 + 0.42 * 0.42 - 2.0 * 0.42 * c, 0.001), 1.5);
    return (narrow * 0.65 + broad * 0.35) / (4.0 * PI);
}

// 水面以上的遮挡沿折射方向回溯到入水点；水内遮挡继续使用原生深度。
// 避免用空气中的太阳方向在水下平移树影，使光束与折射后的太阳中心错位。
float waterRefractedSunVisibility(vec3 position, float waterHeight, vec3 direction) {
    float depth = max(waterHeight - position.y, 0.0);
    vec3 entry = position - direction * (depth / max(-direction.y, 0.2));
    float incident = waterSunVisibility(entry, 0.025);
    if (incident <= 0.0) return 0.0;
    vec4 projected = shadowProjection * shadowModelView * vec4(position - cameraPosition, 1.0);
    vec3 coordinate = distortShadow(projected.xyz / max(projected.w, EPSILON)) * 0.5 + 0.5;
    if (any(lessThan(coordinate, vec3(0.0))) || any(greaterThan(coordinate, vec3(1.0)))) {
        return incident;
    }
    vec2 pixel = shadowTexelCenter(coordinate.xy);
    float depthSample = texture(shadowtex1, pixel).r;
    if (depthSample >= 0.999999) return incident;
    vec4 caster = shadowProjectionInverse
        * vec4(undistortShadow(pixel * 2.0 - 1.0), depthSample * 2.0 - 1.0, 1.0);
    vec3 world = (shadowModelViewInverse * (caster / max(caster.w, EPSILON))).xyz + cameraPosition;
    float submerged = 1.0 - smoothstep(waterHeight - 0.06, waterHeight + 0.06, world.y);
    return incident * mix(1.0, waterSunVisibility(position, 0.025), submerged);
}

// 对分段内的Beer衰减解析积分，低采样数也不会额外改变散射能量。
vec3 waterScatteringSegment(vec3 extinction, float opticalStart, float opticalEnd, float segmentLength) {
    vec3 start = exp(-extinction * opticalStart);
    vec3 end = exp(-extinction * opticalEnd);
    vec3 change = extinction * (opticalEnd - opticalStart);
    vec3 integral;
    for (int channel = 0; channel < 3; channel++) {
        float delta = change[channel];
        integral[channel] = abs(delta) < 0.001
            ? start[channel] * (1.0 - delta * 0.5 + delta * delta / 6.0)
            : (start[channel] - end[channel]) / delta;
    }
    return integral * segmentLength;
}

// 固定步数积分真实阴影和光程。透视使平行的日照阴影在画面中朝太阳聚拢，
// 随视角自然展开；不使用固定的世界噪声条带或屏幕放射纹理。
vec3 integrateWaterShafts(vec2 uv, float pathLength, float eyeDepth, float surfaceSky) {
    float skyLevel = clamp(surfaceSky, 0.0, 1.0);
    vec3 sunlight = getSunLightColor();
    if (UNDERWATER_SHAFT_STRENGTH <= 0.0 || skyLevel <= 0.03 || luma(sunlight) <= 0.001) {
        return vec3(0.0);
    }
    vec3 ray = normalize(mat3(gbufferModelViewInverse) * screenToView(uv, 0.5));
    vec3 direction = waterSunDirection();
    float stepLength = min(pathLength, 48.0) / float(WATER_SHAFT_STEPS);
    // 无时间降噪时采用固定中点，避免随机积分位置形成显眼的像素颗粒。
    const float jitter = 0.5;
    float waterHeight = cameraPosition.y + eyeDepth;
    vec3 extinction = underwaterExtinctionCoefficient();
    vec3 sum = vec3(0.0);
    for (int index = 0; index < WATER_SHAFT_STEPS; index++) {
        float distance = (float(index) + jitter) * stepLength;
        vec3 position = cameraPosition + ray * distance;
        float visibility = waterRefractedSunVisibility(position, waterHeight, direction);
        // 入射光和射向相机的光程一起衰减，使光柱自然融入同一水色。
        float start = float(index) * stepLength;
        float end = start + stepLength;
        float sunPathStart = max(eyeDepth - ray.y * start, 0.0)
            / max(-direction.y, 0.2) * UNDERWATER_DEPTH_DIMMING;
        float sunPathEnd = max(eyeDepth - ray.y * end, 0.0)
            / max(-direction.y, 0.2) * UNDERWATER_DEPTH_DIMMING;
        sum += waterScatteringSegment(extinction, start + sunPathStart, end + sunPathEnd,
            stepLength) * visibility;
    }
    float forwardPhase = waterScatteringPhase(dot(ray, -direction));
    // 水内散射偏向青蓝，避免白色入射光叠在蓝雾上形成灰黄条带。
    // 强度与相函数分别控制，不改变真实遮挡或制造额外光束边界。
    vec3 scattering = (0.015 + WATER_TURBIDITY * 0.5) * vec3(0.22, 0.85, 1.25);
    return sum * sunlight * scattering * forwardPhase * 9.0 * UNDERWATER_SHAFT_STRENGTH
         * smoothstep(0.03, 0.5, skyLevel) * (1.0 - rainStrength * 0.8);
}

#endif


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

/* 透明方块颜色独立于水面保存。RGB 是预乘辐射，alpha 是累计覆盖率；
 * 水面阶段可把这层放在水体之前或之后，水下视角也能保留玻璃。
 */
#ifndef LIB_TRANSPARENCY_GLSL
#define LIB_TRANSPARENCY_GLSL

vec3 applyTransparentLayer(vec3 background, vec4 layer) {
    return layer.rgb + background * (1.0 - clamp(layer.a, 0.0, 1.0));
}

bool transparentLayerInFront(float sceneDepth, float waterDepth, float coverage) {
    return coverage > 0.001 && sceneDepth < waterDepth - max(0.03, waterDepth * 0.001);
}

#endif

/* 相机看不到的倒影遮挡：沿反射光线在不透明阴影贴图里步进。
 *
 * 屏幕空间光线从树冠、桥面后方穿过时，深度缓冲无法区分“在几何体后方”与
 * “被几何体挡住”。阴影贴图从日月方向记录了另一层表面，可以补上这部分信息：
 *   - 光线点在贴图表面前方/后方的符号改变，且两侧贴图深度连续，
 *     说明光线穿过了真实表面。
 *       前 -> 后：从受光面进入实体，命中点就在穿越处。
 *       后 -> 前：从实体内部穿出受光面（桥底、树冠下方的水面），
 *                 之前已经打在相机和日月都看不到的背面上。
 *   - 贴图深度在穿越处跳变，说明只是穿过了阴影边界（空气），不算遮挡。
 * 前后判断留有死区，贴着地面掠过的光线不会因纹素量化被误判为进入地面。
 * 光线离开阴影贴图覆盖范围即停止，远处的遮挡仍由天光衰减近似。
 * 屏幕命中优先；只有遮挡点明显更近时（桥底、树冠下方）才取代屏幕命中。
 */
#ifndef LIB_REFLECTION_OCCLUSION_GLSL
#define LIB_REFLECTION_OCCLUSION_GLSL





// 步进距离（方块）：覆盖常见的树冠、桥面、屋檐高度。
const float REFLECTION_OCCLUSION_RANGE = 24.0;

// 光线点相对贴图表面的有符号距离（方块，正值在表面后方）。
// covered 为假表示已离开阴影贴图。
float reflectionShadowSeparation(vec3 clip, out bool covered) {
    vec3 coordinate = distortShadow(clip) * 0.5 + 0.5;
    covered = all(greaterThan(coordinate, vec3(0.0))) && all(lessThan(coordinate, vec3(1.0)));
    float mapDepth = texture(shadowtex1, shadowTexelCenter(coordinate.xy)).r;
    return shadowDepthToBlocks(coordinate.z - mapDepth);
}

// 点在相机深度缓冲之后（或在屏幕外）：相机看不到它，可能在实体内部。
bool reflectionHiddenFromCamera(sampler2D depths, vec3 pointView) {
    vec4 clip = gbufferProjection * vec4(pointView, 1.0);
    if (clip.w <= 0.0) {
        return true;
    }
    vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
        return true;
    }
    float depth = texture(depths, uv).r;
    return depth < 0.999999 && -pointView.z > -screenToView(uv, depth).z + 0.1;
}

// 返回 xyz：遮挡点（视图空间），w：1 表示被遮挡。
// hidden：命中的是相机看不到的面，不能直接取屏幕颜色。
vec4 reflectionShadowOcclusion(sampler2D depths, vec3 originView, vec3 directionView,
                               out bool hidden, out bool confirmed) {
    hidden = false;
    confirmed = false;
#if REFLECTION_OCCLUSION_STEPS > 0 && ENABLE_SHADOWS == 1 && SIMPLE_DIMENSION == 0
    mat4 toShadow = shadowProjection * shadowModelView * gbufferModelViewInverse;
    // 实体侧面不受光，阴影贴图里看不到从侧面穿出的光线（桥底进、桥侧出）。
    // 穿出阴影区边界时若仍紧贴受光面之后（一格竖直厚度以内），
    // 且相机也看不到该点，视为在遮挡物内部。
    float sunHeight = abs((shadowModelView * vec4(0.0, 1.0, 0.0, 0.0)).z);
    float solidDepth = 1.0 / max(sunHeight, 0.3);
    // 正交投影：阴影裁剪坐标沿光线线性变化。
    vec3 clipOrigin = (toShadow * vec4(originView, 1.0)).xyz;
    vec3 clipDirection = mat3(toShadow) * directionView;
    float texelBlocks = 2.0 / (shadowTextureResolution()
                      * max(abs(shadowProjection[0][0]), EPSILON));
    float previousT = 0.0;
    float previousSeparation = 0.0;
    int previousState = 0;
    for (int index = 0; index <= REFLECTION_OCCLUSION_STEPS; index++) {
        // 二次分布：近处密、远处疏，先发现紧贴水面的树冠和桥底。
        float fraction = float(index) / float(REFLECTION_OCCLUSION_STEPS);
        float t = 0.25 + (REFLECTION_OCCLUSION_RANGE - 0.25) * fraction * fraction;
        vec3 clip = clipOrigin + clipDirection * t;
        // 畸变后的纹素在远处更大，按当前位置估计一个纹素对应的方块数。
        float distortion = (1.0 - SHADOW_MAP_BIAS) + length(clip.xy) * SHADOW_MAP_BIAS;
        // 径向是畸变最强的方向，用它作保守估计。
        float texel = texelBlocks * distortion * distortion / (1.0 - SHADOW_MAP_BIAS);
        bool covered;
        float separation = reflectionShadowSeparation(clip, covered);
        if (!covered) {
            break;
        }
        float deadZone = 0.15 + texel;
        int state = separation > deadZone ? 1 : (separation < -deadZone ? -1 : previousState);
        // 光线经阴影边界进入阴影区后，若紧贴某个受光面之后（两格竖直厚度以内）
        // 且相机也看不到，它已在该实体内部：山体侧面被树影遮住时，
        // 阴影贴图看不到入口，旧版因此透过叶丛露出天空。
        // 树冠、桥面下方的空气离受光的顶面至少隔着叶层或桥面本身，不受影响。
        vec3 point = originView + directionView * t;
        if (index > 0 && state > 0 && previousState > 0 && separation <= solidDepth * 2.0
            && reflectionHiddenFromCamera(depths, point)) {
            hidden = true;
            return vec4(point, 1.0);
        }
        if (index > 0 && previousState != 0 && state != previousState) {
            // 二分到约一个纹素，再看贴图深度在穿越处是否连续。
            float low = previousT;
            float high = t;
            float lowSeparation = previousSeparation;
            float highSeparation = separation;
            for (int iteration = 0; iteration < 5; iteration++) {
                float mid = (low + high) * 0.5;
                bool midCovered;
                float midSeparation = reflectionShadowSeparation(clipOrigin + clipDirection * mid,
                                                                 midCovered);
                if ((midSeparation > 0.0) == (highSeparation > 0.0)) {
                    high = mid;
                    highSeparation = midSeparation;
                } else {
                    low = mid;
                    lowSeparation = midSeparation;
                }
            }
            // 光线点本身最多移动 high-low；超出部分来自贴图深度跳变（阴影边界）。
            float jump = abs(highSeparation - lowSeparation) - (high - low);
            if (jump <= 0.35 + texel * 2.5) {
                hidden = state < 0;
                confirmed = state > 0;
                float hitT = state > 0 ? high : low;
                return vec4(originView + directionView * hitT, 1.0);
            }
            vec3 inside = originView + directionView * low;
            if (state < 0 && lowSeparation <= solidDepth
                && reflectionHiddenFromCamera(depths, inside)) {
                hidden = true;
                return vec4(inside, 1.0);
            }
        }
        if (state != 0) {
            previousState = state;
        }
        previousT = t;
        previousSeparation = separation;
    }
#endif
    return vec4(0.0);
}

// 阴影视图保留的原生材质提供离屏命中的颜色，避免整栋建筑退化成无纹理剪影。
// 只接受不透明/镂空材质，并核对两张深度：水和玻璃覆盖的颜色不能替代其后方表面。
vec3 reflectionShadowMaterial(vec3 hitView, vec3 ambient, out bool validMaterial) {
    validMaterial = false;
    vec4 projected = shadowProjection * shadowModelView * gbufferModelViewInverse
        * vec4(hitView, 1.0);
    vec3 coordinate = distortShadow(projected.xyz / max(projected.w, EPSILON)) * 0.5 + 0.5;
    if (any(lessThan(coordinate, vec3(0.0))) || any(greaterThan(coordinate, vec3(1.0)))) {
        return ambient;
    }
    vec2 uv = shadowTexelCenter(coordinate.xy);
    vec4 material = texture(shadowcolor0, uv);
    bool opaque = abs(material.a - 1.0) < 0.08 || abs(material.a - 0.25) < 0.08;
    float separation = abs(shadowDepthToBlocks(texture(shadowtex0, uv).r
        - texture(shadowtex1, uv).r));
    if (!opaque || separation > 0.1) {
        return ambient;
    }
    validMaterial = true;
    // 回退环境原先含0.3平均反照率；现在改用采集到的实际反照率。
    return toLinearSpace(material.rgb) * ambient / 0.3;
}

// 遮挡点的辐射度：屏幕上可见时取屏幕颜色；被挡住的背面、底面只受环境光照亮，
// 用附近可见面的颜色压暗近似；离屏或投影落在天空上时用调用者给的暗环境色。
// scene 的 alpha 是覆盖/镂空类别标记，RGB始终是非预乘的线性辐射。
vec3 reflectionOccluderRadiance(sampler2D scene, sampler2D depths, vec3 hitView,
                                bool hidden, vec3 ambient) {
    bool validMaterial;
    vec3 materialFallback = reflectionShadowMaterial(hitView, ambient, validMaterial);
    vec4 clip = gbufferProjection * vec4(hitView, 1.0);
    if (clip.w <= 0.0) {
        return materialFallback;
    }
    vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
        return materialFallback;
    }
    float depth = texture(depths, uv).r;
    if (depth >= 0.999999) {
        return materialFallback;
    }
    float sceneDistance = -screenToView(uv, depth).z;
    float hitDistance = -hitView.z;
    // 可见面与遮挡点不在同一深度时，它是别的物体：更远的是透过叶隙看到的山，
    // 更近的是挡在前面的树叶、树干。借用它们压暗后的颜色会在倒影里
    // 沿前景轮廓画出细黑边，统一使用平滑的环境色。
    if (abs(sceneDistance - hitDistance) > max(1.0, hitDistance * 0.04)) {
        return materialFallback;
    }
    vec4 radiance = textureLod(scene, uv, 0.0);
    vec3 surface = radiance.rgb;
    if (!hidden) {
        return surface;
    }
    // 有实际材质时直接按当地环境光估计背面，避免将已受阴影的屏幕颜色再压暗。
    if (validMaterial) {
        return materialFallback;
    }
    // 无有效材质的隐藏面继续保留有界的原有近似。
    return min(surface * 0.35, ambient * 2.0 + surface * 0.1);
}

// 被挡住的面朝向光线来处：陡直向上的光线打到底面（桥底、树冠下方），
// 只受下半球环境光；平缓的光线打到侧面（树影里的山坡），环境光更亮。
// 0.3 近似常见方块的反照率。rayWorld 为世界空间的反射方向。
vec3 reflectionHiddenAmbient(vec3 rayWorld, vec2 lmCoord) {
    return materialAmbientEnvironment(-rayWorld, lmCoord) * 0.3;
}

// 阴影中的空气也可能位于遮挡物之后。原生占用只为隐藏命中提供辅助证据，
// 不产生可见方块或颜色，避免将叶隙后的空气伪造成压黑的反射表面。
bool reflectionHiddenHitSupported(vec3 pointView) {
#if defined(SIMPLE_VARYING) && (ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0)
    if (!lpvHeaderValid(texelFetch(colortex8, ivec2(0), 0))) {
        return false;
    }
    ivec3 cell = ivec3(floor(viewToAbsoluteWorld(pointView))) - lpvOrigin(cameraPosition);
    if (!lpvInside(cell)) {
        return false;
    }
    return lpvFullCubeGeometry(cell) && lpvOpaque(lpvVoxel(cell));
#else
    return false;
#endif
}

// rgb：遮挡物辐射度，a：遮挡权重。REFLECTION_OCCLUSION_STEPS 为 0 时恒为 0。
// hitDistance：遮挡点到起点的距离，未遮挡时为 0。
vec4 reflectionOcclusion(sampler2D scene, sampler2D depths, vec3 originView,
                         vec3 directionView, vec3 ambient, out float hitDistance) {
    // GI体素只代表一格占用与平均颜色，不能作为镜面可见表面。这里查询
    // 原生阴影深度与alpha轮廓，使楼梯、半砖和植物保留实际光栅形状。
    bool hidden;
    bool confirmed;
    vec4 hit = reflectionShadowOcclusion(depths, originView, directionView, hidden, confirmed);
    hitDistance = 0.0;
    if (hit.w <= 0.0) {
        return vec4(0.0);
    }
    hitDistance = length(hit.xyz - originView);
    float confidence = confirmed || reflectionHiddenHitSupported(hit.xyz) ? 1.0 : 0.5;
    // 隐藏面使用同一原生GI场；确认的受光面保留直射，背面不凭空获得日照。
    vec3 normalView = -directionView;
    ambient += companionIndirect(hit.xyz, normalView) * 0.3;
    if (confirmed && !hidden) {
        vec3 light = getLightDirView();
        float cloud = cloudProjectedShadow(viewToAbsoluteWorld(hit.xyz),
            normalize(mat3(gbufferModelViewInverse) * light));
        ambient += (getSunLightColor() + getMoonLightColor())
            * max(dot(normalView, light), 0.0) * cloud * 0.3;
    }
    return vec4(reflectionOccluderRadiance(scene, depths, hit.xyz, hidden, ambient), confidence);
}

// 遮挡点明显比屏幕命中近：屏幕光线从桥底、树冠下方穿过，在远处才打到
// 可见景物（桥后的树林、对岸的山），这个屏幕命中不是真正的倒影。
// 留出余量，同一表面上两种方法的命中误差不会互相覆盖。
bool reflectionOcclusionCloser(vec4 occlusion, float occlusionDistance, float screenDistance) {
    return occlusion.a > 0.75 && (screenDistance <= 0.0
        || occlusionDistance < screenDistance - max(0.15, screenDistance * 0.01));
}

#endif

/* 空气到水的折射。由水面法线和折射率确定一条 Snell 光线，再求水底取样位置。
 * 水面覆盖和水底表面的边界提前收窄偏移，不在不连续的深度之间迭代跳转。
 */
#ifndef LIB_WATER_REFRACTION_GLSL
#define LIB_WATER_REFRACTION_GLSL


uniform sampler2D colortex14;

// 深度属于离散像素；法线、位置与颜色必须使用同一像素中心。
vec2 waterBedUv(vec2 uv) {
    vec2 size = vec2(viewWidth, viewHeight);
    return (clamp(floor(uv * size), vec2(0.0), size - 1.0) + 0.5) / size;
}

// 同一表面的单侧差分避免岸壁深度跳变把水底法线拉向屏外前景。
vec3 waterBedPoint(vec2 pixel, sampler2D opaqueDepth) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 uv = (clamp(pixel, vec2(0.0), size - 1.0) + 0.5) / size;
    float depth = texture(opaqueDepth, uv).r;
    return screenToView(uv, min(depth, 0.99999));
}

vec3 waterBedNormal(vec2 uv, vec3 centre, sampler2D opaqueDepth) {
    vec2 pixel = floor(uv * vec2(viewWidth, viewHeight));
    vec3 left = waterBedPoint(pixel - vec2(1.0, 0.0), opaqueDepth);
    vec3 right = waterBedPoint(pixel + vec2(1.0, 0.0), opaqueDepth);
    vec3 down = waterBedPoint(pixel - vec2(0.0, 1.0), opaqueDepth);
    vec3 up = waterBedPoint(pixel + vec2(0.0, 1.0), opaqueDepth);
    vec3 dx = abs(left.z - centre.z) < abs(right.z - centre.z) ? centre - left : right - centre;
    vec3 dy = abs(down.z - centre.z) < abs(up.z - centre.z) ? centre - down : up - centre;
    vec3 fallback = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    vec3 normal = safeNormalize(cross(dx, dy), fallback);
    normal *= dot(normal, -centre) >= 0.0 ? 1.0 : -1.0;
    return normalize(mat3(gbufferModelViewInverse) * normal);
}

// 先检查每个颜色纹素的几何，再插值；天空黑底、岸上前景与异面颜色不混入水底。
vec3 waterTransmissionColor(sampler2D scene, sampler2D opaqueDepth, vec2 uv,
                            vec3 bedWorld, vec3 bedNormal, float waterHeight) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    float tolerance = max(0.02, length(bedWorld - cameraPosition) * 0.002);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(base + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            vec2 sampleUv = (cell + 0.5) / size;
            float depth = texture(opaqueDepth, sampleUv).r;
            if (depth >= 0.999999) continue;
            vec3 world = viewToAbsoluteWorld(screenToView(sampleUv, depth));
            if (world.y >= waterHeight - 0.005 || abs(dot(world - bedWorld, bedNormal)) > tolerance) continue;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                * (y == 0 ? 1.0 - fraction.y : fraction.y);
            sum += texture(scene, sampleUv).rgb * weight;
            total += weight;
        }
    }
    vec2 centreUv = (clamp(floor(uv * size), vec2(0.0), size - 1.0) + 0.5) / size;
    return total > 0.00001 ? sum / total : texture(scene, centreUv).rgb;
}

// 只接受同一水位下的原生几何；屏外和岸上前景没有可用于水底的颜色。
bool waterRefractionDomain(vec2 uv, vec3 origin, sampler2D opaqueDepth,
                           sampler2D geometry, sampler2D parameters) {
    vec2 inset = 1.0 / vec2(viewWidth, viewHeight);
    if (any(lessThan(uv, inset)) || any(greaterThan(uv, 1.0 - inset))) return false;
    vec2 centre = waterBedUv(uv);
    vec4 water = readWaterSurface(geometry, parameters, centre);
    if (water.a <= 0.001) return false;
    vec3 interfacePoint = viewToAbsoluteWorld(waterSurfacePosition(centre, water.a));
    if (abs(interfacePoint.y - origin.y) > 0.25) return false;
    float depth = texture(opaqueDepth, centre).r;
    if (depth >= 0.999999) return false;
    vec3 point = viewToAbsoluteWorld(screenToView(centre, depth));
    return point.y < interfacePoint.y - 0.005;
}

// 对四个邻近传播结果取真实距离的最小值，不插值种子坐标，避免跨Voronoi边界跳动。
float waterBoundaryDistance(vec2 uv, sampler2D boundaryField) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 point = uv * size * 0.5;
    vec2 base = floor(point - 0.5);
    float distance = min(min(uv.x, 1.0 - uv.x) * size.x,
        min(uv.y, 1.0 - uv.y) * size.y);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 pixel = clamp(base + vec2(float(x), float(y)), vec2(0.0), ceil(size * 0.5) - 1.0);
            vec4 seed = texture(boundaryField, (pixel + 0.5) / size);
            if (seed.a > 0.5) distance = min(distance, length(seed.xy - point) * 2.0);
        }
    }
    return max(distance - 3.0, 0.0);
}

// 在两倍偏移距离内平滑收窄，避免硬拒绝、边界拉丝和两幅水底叠加。
// 三像素余量覆盖半分辨率种子的位置误差及颜色滤波足迹。
float waterRefractionBoundary(vec2 uv, vec2 offset, sampler2D boundaryField) {
    float distance = waterBoundaryDistance(uv, boundaryField);
    return smoothstep(0.0, max(2.0 * length(offset * vec2(viewWidth, viewHeight)), 0.01), distance);
}

vec2 waterRefractionUv(vec2 uv, vec3 position, vec3 normal, vec3 bedWorld,
                       vec3 bedNormal, sampler2D opaqueDepth,
                       sampler2D geometry, sampler2D parameters) {
    if (WATER_REFRACTION_STRENGTH <= 0.0) return uv;
    vec3 origin = viewToAbsoluteWorld(position);
    if (!waterRefractionDomain(uv, origin, opaqueDepth, geometry, parameters)) return uv;
    vec3 incident = normalize(position);
    vec3 ray = refract(incident, normal, 1.0 / WATER_IOR);
    vec3 worldRay = mat3(gbufferModelViewInverse) * ray;
    float denominator = dot(bedNormal, worldRay);
    if (abs(denominator) < 0.04 || worldRay.y > -0.02) return uv;
    float distance = clamp(dot(bedNormal, bedWorld - origin) / denominator, 0.0, 48.0);
    vec4 clip = gbufferProjection * vec4(position + ray * distance, 1.0);
    if (clip.w <= 0.001) return uv;
    vec2 offset = (clip.xy / clip.w * 0.5 + 0.5 - uv) * WATER_REFRACTION_STRENGTH;
    if (length(offset * vec2(viewWidth, viewHeight)) < 0.01) return uv;
    float boundary = waterRefractionBoundary(uv, offset, colortex14);
    vec2 result = uv + offset * boundary;
    return waterRefractionDomain(result, origin, opaqueDepth, geometry, parameters)
        ? result : uv;
}
#endif

/* 世界坐标中的雨滴波环。四个邻域滴点使用解析斜率，避免纹理动画的平铺和跳帧。
 * 半径小于胞元的一半，四邻域足够覆盖；像素足迹过大时连续退出。
 */
#ifndef LIB_RAIN_RIPPLES_GLSL
#define LIB_RAIN_RIPPLES_GLSL


vec3 rainImpactHash(vec2 cell) {
    vec3 value = fract(vec3(cell.xyx) * vec3(0.1031, 0.1030, 0.0973));
    value += dot(value, value.yxz + 33.33);
    return fract((value.xxy + value.yzz) * value.zyx);
}

vec2 rainRippleSlope(vec2 world, float time, float footprint) {
    float rain = weatherRainAmount() * clamp(rainBiome, 0.0, 1.0);
    float resolved = 1.0 - smoothstep(0.035, 0.22, footprint);
    if (RAIN_RIPPLE_STRENGTH <= 0.0 || rain * resolved <= 0.001) {
        return vec2(0.0);
    }
    const float cellSize = 1.6;
    vec2 coordinate = world / cellSize;
    vec2 base = floor(coordinate - 0.5);
    vec2 slope = vec2(0.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = base + vec2(float(x), float(y));
            vec3 seed = rainImpactHash(cell);
            float clock = time * mix(0.9, 1.4, seed.z) + seed.x * 7.0;
            float age = fract(clock);
            vec3 impact = rainImpactHash(cell + floor(clock) * vec2(13.7, 29.3));
            vec2 centre = (cell + 0.3 + impact.xy * 0.4) * cellSize;
            vec2 delta = world - centre;
            float distance = length(delta);
            float radius = 0.035 + age * 0.40;
            float width = sqrt(0.018 * 0.018 + footprint * footprint * 0.7);
            float ring = (distance - radius) / width;
            float envelope = smoothstep(0.0, 0.08, age) * (1.0 - age) * (1.0 - age);
            float derivative = -ring * exp(-0.5 * ring * ring) * 0.004 / width;
            slope += delta / max(distance, 0.001) * derivative * envelope;
        }
    }
    return slope * rain * resolved * RAIN_RIPPLE_STRENGTH;
}
#endif


uniform sampler2D colortex9;
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
#ifdef WORLD_BASE_OPTICS
uniform sampler2D colortex3;
#endif
#ifdef WORLD_REFLECTION_CACHE
/* Water reflection history is independent of display colour and air fog.
 * Finite-word storage preserves HDR, receiver depth and identity in one target.
 * Every read decodes first; packed values must never use hardware interpolation.
 */
#ifndef SIMPLE_WORLD_REFLECTION_HISTORY_GLSL
#define SIMPLE_WORLD_REFLECTION_HISTORY_GLSL



struct WorldReflectionHistory {
    vec3 radiance;
    vec3 normal;
    float depth;
    float confidence;
    int frame;
    int count;
    bool valid;
};

WorldReflectionHistory worldEmptyReflection() {
    return WorldReflectionHistory(vec3(0.0), vec3(0.0, 1.0, 0.0), 0.0, 0.0, -1, 0, false);
}

vec4 worldPackReflection(WorldReflectionHistory value) {
    if (!value.valid) return vec4(0.0);
    uvec4 words = uvec4(0u);
    uvec2 normal = uvec2(round(encodeWaterNormal(value.normal) * 4095.0));
    worldPutRawField(words, waterRgb9e5(value.radiance), 0, 32);
    worldPutRawField(words, normal.x, 32, 12);
    worldPutRawField(words, normal.y, 44, 12);
    worldPutRawField(words, floatBitsToUint(value.depth), 56, 32);
    worldPutRawField(words, uint(value.frame), 88, 20);
    worldPutRawField(words, uint(value.count), 108, 5);
    worldPutRawField(words, uint(round(clamp(value.confidence, 0.0, 1.0) * 15.0)), 113, 4);
    worldPutRawField(words, 5u, 117, 3);
    return worldRawEncode(words, true, false);
}

WorldReflectionHistory worldUnpackReflection(vec4 packedValue) {
    WorldReflectionHistory result = worldEmptyReflection();
    if (!worldRawValid(packedValue)) return result;
    uvec4 words = worldRawDecode(packedValue);
    if (worldGetRawField(words, 117, 3) != 5u) return result;
    result.radiance = waterRgb9e5Value(worldGetRawField(words, 0, 32));
    result.normal = decodeWaterNormal(vec2(worldGetRawField(words, 32, 12),
        worldGetRawField(words, 44, 12)) / 4095.0);
    result.depth = uintBitsToFloat(worldGetRawField(words, 56, 32));
    result.frame = int(worldGetRawField(words, 88, 20));
    result.count = int(worldGetRawField(words, 108, 5));
    result.confidence = float(worldGetRawField(words, 113, 4)) / 15.0;
    result.valid = result.depth > 0.0;
    return result;
}

WorldReflectionHistory worldReflectionHistoryAt(ivec2 pixel) {
    ivec2 size = textureSize(colortex7, 0);
    return worldUnpackReflection(texelFetch(colortex7, clamp(pixel, ivec2(0), size - 1), 0));
}

// Reconstruct only samples on this water plane, with compatible wave normals.
// Thin water/shore contacts that have no valid neighbours use a full query.
vec4 worldWaterReflectionAt(vec2 uv, vec3 position, vec3 normal) {
    ivec2 size = textureSize(colortex7, 0);
    vec2 coordinate = uv * vec2(size) - 0.5;
    ivec2 first = ivec2(floor(coordinate));
    vec2 fraction = fract(coordinate);
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
    float height = viewToWorld(position).y;
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            ivec2 pixel = clamp(first + ivec2(x, y), ivec2(0), size - 1);
            WorldReflectionHistory value = worldReflectionHistoryAt(pixel);
            if (!value.valid || value.frame != frameCounter) continue;
            vec2 sampleUv = (vec2(pixel) + 0.5) / vec2(size);
            vec3 point = waterSurfacePosition(sampleUv, value.depth);
            float heightError = abs(viewToWorld(point).y - height);
            float agreement = dot(normalWorld, value.normal);
            if (heightError > 0.08 || agreement < 0.94) continue;
            float spatial = (x == 0 ? 1.0 - fraction.x : fraction.x)
                * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = spatial * exp(-heightError * 20.0) * pow(agreement, 24.0);
            sum += value.radiance * weight;
            total += weight;
        }
    }
    return total > 0.05 ? vec4(sum / total, 1.0) : vec4(0.0);
}
#endif

#endif

// Colour reconstruction validates each mip-zero texel against the hit plane.
vec4 filteredWaterReflection(vec2 uv, float distanceToHit, float hitDepth, float roughness) {
    return reflectionSourceFiltered(colortex6, depthtex1, uv, hitDepth, distanceToHit, roughness);
}

// 判断倒影中的点是否在水面以下：水下的方块不应出现在水面倒影里。
bool waterReflectionSubmerged(vec2 uv, vec3 origin) {
    vec2 pixelUv = reflectionPixelUv(uv);
    vec3 scene = screenToView(pixelUv, texture(depthtex1, pixelUv).r);
    return viewToAbsoluteWorld(scene).y < viewToAbsoluteWorld(origin).y - 0.12;
}

// 水面与固体、玻璃材质共用同一套屏幕空间求交。
vec4 traceWaterScene(vec3 origin, vec3 direction, float roughness,
    out float distanceToHit, out float confidence) {
    distanceToHit = 0.0;
    confidence = 1.0;
    // 水面本身不在不透明深度里，最近命中距离为 0：紧贴岸壁、树干的水面
    // 必须能命中几厘米外的墙面。旧版 0.25 格的下限让每条岸线都带一条天空色亮带。
    // 范围覆盖整个渲染距离，远山、远处树林不再渐变成天空。
    // 水面以下（0.12 格余量）的像素对水面以上的光线不存在。
    vec3 up = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    vec4 waterPlane = vec4(up, 0.12 - dot(up, origin));
    int budget = WATER_REFLECTION_STEPS;
#ifdef WORLD_GPU_BACKEND
    // Contact reflections have little travel distance but need enough shrinking
    // steps to resolve an actual bank rather than a broad depth approximation.
    vec4 originClip = gbufferProjection * vec4(origin, 1.0);
    vec2 originUv = originClip.xy / originClip.w * 0.5 + 0.5;
    vec2 bedUv = reflectionPixelUv(originUv);
    float bedDepth = texture(depthtex1, bedUv).r;
    if (bedDepth < 0.999999) {
        float separation = length(screenToView(bedUv, bedDepth) - origin);
        if (separation < 1.0) budget = max(budget, 32);
    }
#endif
    ScreenReflectionHit traced = traceAdaptiveReflectionDetailed(colortex6, depthtex1,
        origin, direction, 0.001, far, budget, waterPlane);
    vec4 hit = vec4(traced.uv, traced.distance, traced.coverage);
    confidence = traced.confidence;
    // 用命中像素上的可见表面判断是否在水下；薄命中时光线点本身位于物体内部。
    if (hit.a <= 0.0 || waterReflectionSubmerged(hit.xy, origin)) {
        return vec4(0.0);
    }
    distanceToHit = hit.z;
    float hitDepth = reflectionSceneDepth(depthtex1, hit.xy);
    vec4 radiance = filteredWaterReflection(hit.xy, distanceToHit, hitDepth, roughness);
    return vec4(reflectionAirMedium(radiance.rgb, hit.z, direction), hit.a * radiance.a);
}

vec4 traceWaterScene(vec3 origin, vec3 direction, float roughness, out float distanceToHit) {
    float confidence;
    return traceWaterScene(origin, direction, roughness, distanceToHit, confidence);
}

// 自适应步进在镂空轮廓附近可能耗尽预算。已知有遮挡时，再用透视深度DDA
// 找实际屏幕表面，优先恢复纹理；不会对整片天空重复追踪。
vec4 recoverWaterScene(vec3 origin, vec3 direction, float roughness, out float distanceToHit) {
    distanceToHit = 0.0;
    vec3 up = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    vec4 waterPlane = vec4(up, 0.12 - dot(up, origin));
    bool thinHit;
    vec4 hit = traceScreenReflection(depthtex1, origin, direction, 0.001, far,
        min(max(WATER_REFLECTION_STEPS, 24), 64), waterPlane, thinHit);
    if (hit.a <= 0.0 || waterReflectionSubmerged(hit.xy, origin)) {
        return vec4(0.0);
    }
    distanceToHit = hit.z;
    vec4 radiance = filteredWaterReflection(hit.xy, hit.z,
        reflectionSceneDepth(depthtex1, hit.xy), roughness);
    return vec4(reflectionAirMedium(radiance.rgb, hit.z, direction), radiance.a);
}

// 屏幕光线未命中时，用阴影贴图判断相机看不到的遮挡（桥底、树冠下方、悬崖内侧）。
// skyLevel 为水面处的天光可见度，决定被挡背面的环境光。
vec4 waterReflectionOcclusion(vec3 origin, vec3 direction, float skyLevel,
                              float screenDistance, out float hitDistance) {
    vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * direction);
    vec3 ambient = reflectionHiddenAmbient(rayWorld, vec2(0.0, 0.03125 + 0.9375 * skyLevel));
#ifdef WORLD_GPU_BACKEND
    vec3 up = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    vec4 waterPlane = vec4(up, 0.12 - dot(up, origin));
    float maximum = screenDistance > 0.0
        ? screenDistance + max(0.05, screenDistance * 0.015) : far;
    return reflectionOcclusionPlane(colortex6, depthtex1, origin, direction, ambient,
        waterPlane, maximum, hitDistance);
#else
    return reflectionOcclusion(colortex6, depthtex1, origin, direction, ambient, hitDistance);
#endif
}

// 水的 Fresnel。物理上的 Schlick 曲线（F0 = 0.02，五次方）在常见的俯视角下
// 几乎不反射，水面因此被水色主导。这里参考 Sildur 的做法：略高的 F0 与四次方
// 曲线，使中等角度也能看到明显的天空和景物倒影；粗糙水面在掠射时略降低峰值。
float waterFresnel(float cosine, float roughness) {
    float f0 = 0.05;
    float grazing = max(1.0 - roughness * 0.6, f0);
    return f0 + (grazing - f0) * pow4(1.0 - clamp(cosine, 0.0, 1.0));
}

// 天空回退保留同一套天空/云输入；封闭水域的天空辐射为零。
vec3 waterEnvironment(vec3 originWorld, vec3 rayWorld, float skyVisibility, bool celestial) {
#if SIMPLE_DIMENSION == 1
    return mix(dimensionAmbient(rayWorld) * AMBIENT_STRENGTH,
               skyAtmosphereRadiance(rayWorld) * 1.8, END_ATMOSPHERE * 0.65);
#elif SIMPLE_DIMENSION == -1
    return dimensionAmbient(rayWorld) * AMBIENT_STRENGTH;
#endif
    if (skyVisibility <= 0.001) {
        return vec3(0.0);
    }
    vec3 sky = skyAtmosphereRadiance(rayWorld) + skyStars(rayWorld);
    if (celestial) {
        sky += skyCelestialRadiance(rayWorld);
    }
#if WATER_REFLECTION_CLOUDS == 1
    vec4 cloud = traceVolumetricCloudsFrom(originWorld, rayWorld, CLOUD_DISTANCE, true);
#else
    vec4 cloud = cloudEnvironment(rayWorld);
#endif
    return (cloud.rgb + sky * (1.0 - cloud.a)) * skyVisibility;
}

// Query unweighted reflected radiance before the water BRDF and air medium.
// Confidence guides temporal reuse; it never acts as a sky blend opacity.
vec4 queryWaterRadiance(vec3 position, vec3 direction, float roughness, float skyLevel) {
    vec3 originWorld = viewToAbsoluteWorld(position);
    float screenDistance;
    float screenConfidence;
    vec4 screen = traceWaterScene(position + mat3(gbufferModelView) * vec3(0.0, 0.001, 0.0),
        direction, roughness, screenDistance, screenConfidence);
    float worldDistance;
    vec4 world = waterReflectionOcclusion(position, direction, skyLevel, screenDistance, worldDistance);
    if (screen.a <= 0.0 && world.a > 0.0) {
        vec3 origin = position + mat3(gbufferModelView) * vec3(0.0, 0.001, 0.0);
        vec4 recovered = recoverWaterScene(origin, direction, roughness, screenDistance);
        if (recovered.a > 0.0) {
            screen = recovered;
        }
    }
    // 屏幕命中已经包含真实纹理和光照；同一距离的回退不能用平均环境色覆盖它。
    if (reflectionOcclusionCloser(world, worldDistance, screenDistance)) {
        return vec4(world.rgb, 0.9);
    }
    if (screen.a >= 0.999) return vec4(screen.rgb, 1.0);
    // 缺少屏幕命中时仍保留隐藏面的保守回退；低置信度不能压掉已有真实纹理。
    if (world.a > 0.0 && screen.a <= 0.0) return vec4(world.rgb, 0.6);
    vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * direction);
    vec3 environment = waterEnvironment(originWorld, rayWorld,
        reflectionSkyLightWeight(skyLevel), false);
    return vec4(mix(environment, screen.rgb, screen.a), 0.25);
}

// 折射改变水底的投影位置；吸收仍由采样处的真实水内距离决定。
vec3 applyWaterReflection(vec3 color, vec2 uv, float normalVariance) {
    vec4 surface = readWaterSurface(colortex9, colortex1, uv);
    if (surface.a <= 0.001 || isEyeInWater != 0) {
        return color;
    }
    vec3 position = waterSurfacePosition(uv, surface.a);
    vec3 normal = decodeWaterNormal(surface.xy);
    vec3 incident = normalize(position);
    vec3 originWorld = viewToAbsoluteWorld(position);
    vec4 scattering = vec4(readWaterScattering(colortex9, colortex7, uv), 1.0);

    float opaqueDepth = texture(depthtex1, uv).r;
    vec3 opaquePosition = screenToView(uv, min(opaqueDepth, 0.99999));
    vec3 opaqueWorld = viewToAbsoluteWorld(opaquePosition);
    vec3 receiverNormal = waterBedNormal(uv, opaquePosition, depthtex1);
    // 透射采用实际位移高度场的斜率；放大的微表面高光法线不代表一整段水柱的几何。
    // 水底变浅与波浪偏折均来自下方同一次 Snell 求解，不额外变换水底深度。
    vec3 opticalNormal = vec3(0.0, 1.0, 0.0);
#if ENABLE_WATER_WAVES == 1
    opticalNormal = getWaterWaveNormal(originWorld.xz, frameTimeCounter);
#endif
    float footprint = 2.0 * abs(gbufferProjectionInverse[1][1]) * length(position)
        / (max(viewHeight, 1.0) * max(abs(dot(normalize(position),
            mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0))), 0.1));
    vec2 rainSlope = rainRippleSlope(originWorld.xz, frameTimeCounter, footprint)
        * smoothstep(0.95, 0.995, surface.b);
    opticalNormal = mat3(gbufferModelView)
        * normalize(opticalNormal + vec3(-rainSlope.x, 0.0, -rainSlope.y));
    vec2 transmittedUv = opaqueDepth < 0.999999
        ? waterRefractionUv(uv, position, opticalNormal, opaqueWorld, receiverNormal,
            depthtex1, colortex9, colortex1) : uv;
    vec2 sourceUv = waterBedUv(transmittedUv);
    opaqueDepth = texture(depthtex1, sourceUv).r;
    opaquePosition = screenToView(sourceUv, min(opaqueDepth, 0.99999));
    opaqueWorld = viewToAbsoluteWorld(opaquePosition);
    receiverNormal = waterBedNormal(sourceUv, opaquePosition, depthtex1);
    // 水后的玻璃等与水底使用同一折射坐标；岸上的前景层继续由主像素合成。
    vec4 backgroundLayer = texture(colortex2, sourceUv);
    vec4 sourceWater = readWaterSurface(colortex9, colortex1, sourceUv);
    float sourceDepth = -screenToView(sourceUv, texture(depthtex0, sourceUv).r).z;
    if (transparentLayerInFront(sourceDepth, sourceWater.a, backgroundLayer.a)) {
        backgroundLayer = vec4(0.0);
    }
    float verticalDepth = max(originWorld.y - opaqueWorld.y, 0.0);
    float waterDistance = opaqueDepth < 0.999999 ? length(opaquePosition - position) : 24.0;
    waterDistance = clamp(waterDistance, 0.0, 48.0);
#ifdef WORLD_BASE_OPTICS
    vec3 transmitted = applyTransparentLayer(waterTransmissionColor(colortex3, depthtex1,
        transmittedUv, opaqueWorld, receiverNormal, originWorld.y), backgroundLayer);
#else
    vec3 transmitted = applyTransparentLayer(waterTransmissionColor(colortex6, depthtex1,
        transmittedUv, opaqueWorld, receiverNormal, originWorld.y), backgroundLayer);
#endif
    if (opaqueDepth < 0.999999) {
        transmitted *= waterCausticGain(opaqueWorld, receiverNormal, originWorld.y, surface.b);
    }

    // 水上观察时增加随光程累积的散射遮蔽，浅水保留水底，深水以水色为主。
    // 此密度只用于水面合成，避免同时缩短水下相机的可见距离。
    vec3 extinction = waterExtinctionCoefficient() + vec3(WATER_SURFACE_OPACITY * 3.0);
    vec3 transmittance = exp(-extinction * waterDistance);
    transmitted *= transmittance;
    // 遮蔽水底的部分由受光水色补足，不再额外折半，避免不透明深水趋近蓝黑。
    transmitted += scattering.rgb * (1.0 - transmittance);
    // 浅水薄层逐渐变透明，使近岸与水底细节自然显现。
    float surfaceOpacity = texture(colortex1, uv).g * smoothstep(0.0, 1.5, verticalDepth);
    transmitted = mix(transmitted, scattering.rgb, surfaceOpacity);

    vec3 reflected = vec3(0.0);
    float roughness = sqrt(sqrt(pow4(WATER_ROUGHNESS) + min(2.0 * normalVariance, 0.035)));
    float coherence = 1.0 / (1.0 + roughness);
    vec3 geometricNormal = normalize(mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0));
    // 水下窗口需要清晰的波浪起伏；水上倒影使用更平缓的光学斜率，
    // 避免同一组放大法线把相邻倒影拉成相互交叠的碎片。
    vec3 reflectionNormal = normalize(mix(geometricNormal, normal, 0.45));
    vec3 direction = normalize(reflect(incident, reflectionNormal));
    float visibility = reflectionGeometricVisibility(dot(geometricNormal, -incident),
        dot(geometricNormal, direction), roughness);
    float weight = waterFresnel(dot(reflectionNormal, -incident), roughness)
        * WATER_REFLECTION_STRENGTH * visibility;
    if (dot(reflectionNormal, -incident) <= 0.0) weight = 0.0;
    if (weight > 0.001) {
        vec4 radiance = vec4(0.0);
#if defined(WORLD_REFLECTION_CACHE) && !defined(WORLD_REFLECTION_CACHE_WRITE)
        if (waterDistance >= 1.0) {
            radiance = worldWaterReflectionAt(uv, position, reflectionNormal);
        }
#endif
        if (radiance.a <= 0.0) {
            radiance = queryWaterRadiance(position, direction, roughness, surface.b);
        }
        reflected = radiance.rgb * WATER_REFLECTION_BRIGHTNESS;
    }
    // 倒影直接与透射混合：夜晚、雨天的天空暗而灰，水面也随之变暗、变灰。
    vec3 result = mix(transmitted, reflected, weight);

    vec4 shadowClip = shadowProjection * shadowModelView * gbufferModelViewInverse * vec4(position, 1.0);
    float directSky = smoothstep(0.80, 0.99, surface.b);
    if (directSky > 0.001 && WATER_REFLECTION_STRENGTH * WATER_SPECULAR_STRENGTH > 0.0) {
        float directVisibility = waterOpaqueShadow(shadowClip, normal, length(position)) * directSky;
        directVisibility *= cloudProjectedShadow(originWorld,
            normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
        // 随机噪声法线的高频成分比正弦多，高光下限略放宽，避免远处一片细碎白点。
        float glintRoughness = sqrt(sqrt(pow4(max(WATER_ROUGHNESS * 0.6, 0.15))
                                       + min(2.0 * normalVariance, 0.035)));
        result += waterDirectSpecular(normal, position, glintRoughness) * directVisibility
                * WATER_REFLECTION_STRENGTH * WATER_SPECULAR_STRENGTH * coherence;
    }
    result = applyFog(result, length(position));
    return result;
}

#endif

uniform sampler2D colortex0;
/* 水下光学合成。水上景物随水面波浪扭动，水下前景保持原坐标；
 * 水下几何独立接收光程衰减、模拟焦散与按深度重建的半分辨率光柱。
 */
#ifndef LIB_UNDERWATER_GLSL
#define LIB_UNDERWATER_GLSL

/* Shared viewport shape for clouds, air scattering and underwater shafts.
 * Buffers keep full attachment sizes; generation and reconstruction must agree
 * on the active lower-left region, including odd internal render dimensions.
 */
#ifndef LIB_VOLUME_RESOLUTION_GLSL
#define LIB_VOLUME_RESOLUTION_GLSL



vec2 volumeSize() {
#if VOLUMETRIC_RESOLUTION == 0
    return max(floor(vec2(viewWidth, viewHeight) * 0.25), vec2(1.0));
#else
    return max(floor(vec2(viewWidth, viewHeight) * 0.5), vec2(1.0));
#endif
}
#endif



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


/* 水面与积水共用的随机风浪层：带解析导数的值噪声，加上旋转与拉伸。
 * 不依赖任何 uniform，水面（gbuffers_water）与积水（deferred1）都可以直接引用。
 */
#ifndef LIB_WAVE_NOISE_GLSL
#define LIB_WAVE_NOISE_GLSL

// 不使用 sin 的整数格点哈希，在较大的世界坐标下仍保持稳定，结果位于 [0, 1)。
float waterNoiseHash(vec2 cell) {
    vec3 p = fract(vec3(cell.x, cell.y, cell.x) * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

// 带解析导数的值噪声。返回 (值, d/dx, d/dy)，值域约为 [-1, 1]。
// 五次插值 u = 6f^5 - 15f^4 + 10f^3 让一阶、二阶导数在格点处都连续，
// 法线因此没有格子接缝。
vec3 waterValueNoise(vec2 p) {
    vec2 cell = floor(p);
    vec2 f = p - cell;
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float a = waterNoiseHash(cell);
    float b = waterNoiseHash(cell + vec2(1.0, 0.0));
    float c = waterNoiseHash(cell + vec2(0.0, 1.0));
    float d = waterNoiseHash(cell + vec2(1.0, 1.0));
    float k1 = b - a;
    float k2 = c - a;
    float k3 = a - b - c + d;
    float value = a + k1 * u.x + k2 * u.y + k3 * u.x * u.y;
    vec2 gradient = du * vec2(k1 + k3 * u.y, k2 + k3 * u.x);
    return vec3(value, gradient) * 2.0 - vec3(1.0, 0.0, 0.0);
}

// 一层风浪：angle 为传播方向（弧度），wavelength 为传播方向上的格距（方块），
// stretch 为波峰方向的拉长倍数，speed 为传播速度（方块/秒），height 为振幅。
// footprint 是一个像素覆盖的世界宽度。返回该层高度场在世界 XZ 上的斜率。
vec2 waterWaveOctave(vec2 position, float time, float angle, float wavelength,
                     float stretch, float speed, float height, vec2 seed, float footprint) {
    // 像素足迹接近格距的 1/4 时，噪声的高频部分已经开始混叠，提前淡出。
    float resolved = 1.0 - smoothstep(0.08, 0.30, footprint / wavelength);
    if (resolved <= 0.0) {
        return vec2(0.0);
    }
    vec2 along = vec2(cos(angle), sin(angle));
    vec2 across = vec2(-along.y, along.x);
    vec2 scale = vec2(1.0 / wavelength, 1.0 / (wavelength * stretch));
    vec2 q = vec2(dot(position, along), dot(position, across)) * scale + seed;
    q.x -= time * speed * scale.x;
    vec3 noise = waterValueNoise(q);
    // 链式法则：dq/dposition 的两行分别是 along*scale.x 与 across*scale.y。
    vec2 slope = along * (noise.y * scale.x) + across * (noise.z * scale.y);
    return slope * height * resolved;
}

#endif



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


#ifndef WORLD_GPU_BACKEND
uniform sampler2D colortex15;
uniform sampler2D depthtex2;
#endif
SIMPLE_VARYING vec3 vUnderwaterTint;
SIMPLE_VARYING vec3 vUnderwaterScatter;
#ifdef WORLD_BASE_OPTICS
SIMPLE_VARYING float vUnderwaterDepth;
#define underwaterOpaqueSource colortex3
#else
#define underwaterOpaqueSource colortex6
#endif

/* Reconstruct the reduced underwater shaft field using optical path depth.
 * The first texel is frame metadata and never contributes shaft radiance. */
#ifndef LIB_WATER_SHAFTS_FILTER_GLSL
#define LIB_WATER_SHAFTS_FILTER_GLSL
float estimateUnderwaterDepth() {
#ifdef WORLD_BASE_OPTICS
    return vUnderwaterDepth;
#else
    return texture(colortex4, vec2(0.5) / vec2(viewWidth, viewHeight)).a;
#endif
}

// alpha 保存积分终点，拒绝跨越近处遮挡物的散射，首个元数据纹素不参与重建。
vec3 sampleWaterShafts(vec2 uv, float pathLength) {
    if (UNDERWATER_SHAFT_STRENGTH <= 0.0) {
        return vec3(0.0);
    }
    vec2 size = volumeSize();
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    float distance = min(pathLength, 48.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(base + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            if (cell.x < 0.5 && cell.y < 0.5) {
                continue;
            }
            vec4 fieldSample = texture(colortex4, (cell + 0.5) / vec2(viewWidth, viewHeight));
            float spatial = (x == 0 ? 1.0 - fraction.x : fraction.x)
                          * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = spatial * exp(-abs(fieldSample.a - distance) / max(distance * 0.08, 0.15));
            sum += fieldSample.rgb * weight;
            total += weight;
        }
    }
    return total > EPSILON ? sum / total : vec3(0.0);
}

#endif


// OptiFine在手持模型之前复制depthtex2；配对附件只含实际场景，正常手部不变。
float underwaterExitDepth(vec2 uv) {
#ifndef WORLD_GPU_BACKEND
    return texture(depthtex2, uv).r;
#else
    return texture(depthtex1, uv).r;
#endif
}

vec3 underwaterExitOpaqueColor(vec2 uv) {
#ifndef WORLD_GPU_BACKEND
    return texture(colortex15, uv).rgb;
#else
    return texture(underwaterOpaqueSource, uv).rgb;
#endif
}

// 判断偏移坐标是否仍在水上景物中，只拒绝水下前景，不锁死水上物体轮廓。
bool isUnderwaterAirSample(vec2 uv, float waterHeight) {
    float depth = underwaterExitDepth(uv);
    if (depth >= 0.999999) {
        return skyViewDirection(uv).y > 0.01;
    }
    vec3 position = screenToView(uv, depth);
    return viewToAbsoluteWorld(position).y > waterHeight + 0.015;
}

// 只在水下前景附近渐退偏移，水上物体与天空之间的轮廓可一起随波浪移动。
vec2 underwaterWaveUv(vec2 uv, vec2 offset, float waterHeight) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 search = offset;
    float safe = 0.0;
    float unsafe = 1.0;
    for (int index = 0; index < 6; index++) {
        float scale = index == 0 ? 1.0 : (safe + unsafe) * 0.5;
        vec2 candidate = clamp(uv + search * scale, vec2(0.001), vec2(0.999));
        if (isUnderwaterAirSample(candidate, waterHeight)) {
            safe = scale;
            if (index == 0) {
                break;
            }
        } else {
            unsafe = scale;
        }
    }
    float fade = smoothstep(0.0, 1.0, safe);
    return clamp(uv + offset * fade, 0.5 / size, 1.0 - 0.5 / size);
}

// 反射源刻意把天空留黑；水下出射必须从天空表恢复背景，并让实际几何继续遮挡它。
vec3 underwaterBackgroundColor(vec2 uv) {
    if (texture(depthtex1, uv).r < 0.999999) {
        return texture(underwaterOpaqueSource, uv).rgb;
    }
    vec3 direction = skyViewDirection(uv);
    vec4 cloud = cloudEnvironment(direction);
    return cloud.rgb + skyRadiance(direction) * (1.0 - cloud.a);
}

// 只用于向水上的折射，水内全反射仍使用包含玩家/手持物的原有场景输入。
vec3 underwaterExitBackgroundColor(vec2 uv) {
    if (underwaterExitDepth(uv) < 0.999999) {
        return underwaterExitOpaqueColor(uv);
    }
    vec3 direction = skyViewDirection(uv);
    vec4 cloud = cloudEnvironment(direction);
    return cloud.rgb + skyRadiance(direction) * (1.0 - cloud.a);
}

// 每个纹素先恢复自己的背景，再做连续插值，保留岸边轮廓和玻璃独立透明层。
vec3 sampleWaterExitColor(vec2 uv, out vec4 transparentLayer) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 weight = fract(pixel);
    vec3 sum = vec3(0.0);
    transparentLayer = vec4(0.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(base + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            vec2 sampleUv = (cell + 0.5) / size;
            float fraction = (x == 0 ? 1.0 - weight.x : weight.x)
                           * (y == 0 ? 1.0 - weight.y : weight.y);
            sum += underwaterExitBackgroundColor(sampleUv) * fraction;
            transparentLayer += texture(colortex2, sampleUv) * fraction;
        }
    }
    return sum;
}

// 全反射只查询水下场景。离屏或无命中时使用受当地照明控制的水色。
vec3 underwaterInterfaceReflection(vec3 interfaceView, vec3 direction, float waterHeight) {
    vec3 fallback = vUnderwaterScatter
        + vec3(0.004, 0.012, 0.018) * UNDERWATER_MIN_VISIBILITY;
    vec3 down = mat3(gbufferModelView) * vec3(0.0, -1.0, 0.0);
    ScreenReflectionHit hit = traceAdaptiveReflectionDetailed(underwaterOpaqueSource, depthtex1,
        interfaceView + down * 0.025, direction, 0.03, 24.0,
        min(WATER_REFLECTION_STEPS, 16), vec4(down, 0.02 - dot(down, interfaceView)));
    if (hit.coverage <= 0.0) {
        return fallback;
    }
    float depth = texture(depthtex1, hit.uv).r;
    vec3 world = viewToAbsoluteWorld(screenToView(hit.uv, min(depth, 0.99999)));
    if (depth >= 0.999999 || world.y > waterHeight + 0.02) {
        return fallback;
    }
    vec3 radiance = texture(underwaterOpaqueSource, hit.uv).rgb;
    return mix(fallback, applyUnderwaterVolume(radiance, hit.distance,
        vUnderwaterTint, vUnderwaterScatter), hit.coverage);
}

vec3 applyUnderwaterOptics(vec2 uv, float sceneDepth) {
    float eyeDepth = estimateUnderwaterDepth();
    float opaqueDepth = texture(depthtex1, uv).r;
    // 天空只需要方向；避免在无限远投影的 depth=1 处除以零。
    vec3 opaquePosition = screenToView(uv, opaqueDepth < 0.999999 ? opaqueDepth : 0.5);
    vec3 opaqueWorld = viewToAbsoluteWorld(opaquePosition);
    vec4 surface = readWaterSurface(colortex9, colortex1, uv);
    float path = underwaterVisiblePath(uv, opaqueDepth, surface.a, eyeDepth);
    float sceneDistance = opaqueDepth < 0.999999 ? length(opaquePosition) : far;
    vec3 rayWorld = skyViewDirection(uv);
    float waterHeight = cameraPosition.y + eyeDepth;
    float aboveGeometry = opaqueDepth >= 0.999999 ? 1.0
        : smoothstep(waterHeight + 0.015, waterHeight + 0.20, opaqueWorld.y);
    float airCoverage = smoothstep(0.02, 0.20, sceneDistance - path)
                      * smoothstep(0.01, 0.08, rayWorld.y) * aboveGeometry;
    vec3 interfaceWorld = cameraPosition + rayWorld * path;
    float footprint = max(length(dFdx(interfaceWorld.xz)), length(dFdy(interfaceWorld.xz)));
    // 优先使用原生水面写入的同一套细节法线，波峰与临界角边界一起运动。
    vec3 waveNormal = vec3(0.0, 1.0, 0.0);
#if ENABLE_WATER_WAVES == 1
    waveNormal = waterSurfaceNormal(interfaceWorld.xz, frameTimeCounter, footprint);
#endif
    // 原生法线也包含独立落雨涟漪；关闭风浪时仍保留这些界面扰动。
    if (surface.a > 0.001) {
        vec3 captured = mat3(gbufferModelViewInverse) * decodeWaterNormal(surface.xy);
        waveNormal = captured * (captured.y < 0.0 ? -1.0 : 1.0);
    }
    float cosine = clamp(dot(rayWorld, waveNormal), 0.0, 1.0);
    float discriminant = 1.0 - WATER_IOR * WATER_IOR * (1.0 - cosine * cosine);
    float edgeWidth = max(fwidth(discriminant) * 1.5, 0.008);
    float window = smoothstep(-edgeWidth, edgeWidth, discriminant);
    float reflectance = waterDielectricFresnel(cosine, WATER_IOR);
    vec3 radiance = texture(colortex0, uv).rgb;
    if (texture(colortex9, uv).a > 0.5) {
        radiance = applyTransparentLayer(underwaterBackgroundColor(uv), texture(colortex2, uv));
    }
    if (airCoverage > 0.001) {
        vec3 interfaceView = waterSurfacePosition(uv, surface.a > 0.001 ? surface.a : -opaquePosition.z);
        if (surface.a <= 0.001) {
            interfaceView = worldToView(interfaceWorld - cameraPosition);
        }
        vec3 reflectedDirection = mat3(gbufferModelView) * reflect(rayWorld, waveNormal);
        vec3 reflection = underwaterInterfaceReflection(interfaceView, reflectedDirection, waterHeight);
        vec3 air = reflection;
        if (window > 0.001 && discriminant > 0.0) {
            vec3 airDirection = normalize(refract(rayWorld, -waveNormal, WATER_IOR));
            vec3 sampleDirection = normalize(mix(rayWorld, airDirection, WATER_REFRACTION_STRENGTH));
            float airDistance = opaqueDepth < 0.999999 ? max(sceneDistance - path, 0.5) : 128.0;
            vec3 target = interfaceView + mat3(gbufferModelView) * sampleDirection * airDistance;
            vec4 clip = gbufferProjection * vec4(target, 1.0);
            vec2 projected = clip.xy / max(clip.w, 0.001) * 0.5 + 0.5;
            bool inside = clip.w > 0.001 && all(greaterThan(projected, vec2(0.001)))
                && all(lessThan(projected, vec2(0.999)));
            vec4 cloud = cloudEnvironment(sampleDirection);
            air = cloud.rgb + skyRadiance(sampleDirection) * (1.0 - cloud.a);
            vec2 radianceUv = uv;
            if (inside) {
                radianceUv = underwaterWaveUv(uv, projected - uv, waterHeight);
                if (underwaterExitDepth(radianceUv) < 0.999999) {
                    vec4 transparentLayer;
                    air = sampleWaterExitColor(radianceUv, transparentLayer);
                    air = applyTransparentLayer(air, transparentLayer);
                }
            }
#if DEBUG_VIEW == 0
            if (rainStrength > 0.001 && inside) {
                bool waterPresent = texture(colortex9, radianceUv).a > 0.5;
                air = applyRainOverlay(air, texture(colortex1, radianceUv), waterPresent);
            }
#endif
        }
        vec3 interfaceRadiance = mix(reflection, air, (1.0 - reflectance) * window);
        radiance = mix(radiance, interfaceRadiance, airCoverage);
    }
    vec3 normalWorld = waterReceiverNormal(opaqueWorld);
    if (opaqueDepth < 0.999999) {
        float skyVisibility = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
        radiance *= waterCausticGain(opaqueWorld, normalWorld,
            cameraPosition.y + eyeDepth, skyVisibility);
    }
    vec3 result = applyUnderwaterVolume(radiance, path, vUnderwaterTint, vUnderwaterScatter);
#ifndef WORLD_BASE_OPTICS
    result += sampleWaterShafts(uv, path);
#endif
    return result;
}

#endif

/* Near-scene media share the existing reduced-resolution volume attachment.
 * Terrain mist is depth-clipped and visibility-bounded; dimension haze reuses
 * the companion's diffuse SH field for soft local glow. Optical-depth blending
 * avoids adding two independent full-strength veils in overlapping air.
 */
#ifndef LIB_ATMOSPHERE_MEDIA_GLSL
#define LIB_ATMOSPHERE_MEDIA_GLSL
/* 近地面日光的单次体积散射。真实阴影限制入射光，Beer-Lambert 同时约束
 * 透射损失与散射增益；复用半分辨率场，不使用屏幕径向模糊或时间随机噪声。
 */
#ifndef LIB_AIR_SCATTERING_GLSL
#define LIB_AIR_SCATTERING_GLSL


/* 日光体积阴影缓存。固定高度层积分云消光，世界坐标网格随相机平移时按格移动。
 * 缓存位于天空 LUT 右侧的 alpha 区域，沿光线投影后可查询任意近地面体积点。
 */
#ifndef LIB_AIR_SHADOW_GLSL
#define LIB_AIR_SHADOW_GLSL



const float AIR_SHADOW_EXTENT = 256.0;

vec2 airShadowOrigin() {
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0));
    vec2 cell = vec2(2.0 * AIR_SHADOW_EXTENT) / size;
    return floor(cameraPosition.xz / cell) * cell;
}

// 以固定云层高度采样，避免几何终点或像素深度重排采样位置。
float buildAirCloudShadow(vec2 coordinate, vec3 sun) {
#if SIMPLE_DIMENSION != 0
    return 1.0;
#endif
    if (sun.y <= 0.02 || CLOUD_OPACITY <= 0.0 || CLOUD_SHADOW_STRENGTH <= 0.0) {
        return 1.0;
    }
    vec2 altitude = cloudAltitudeBounds();
    float bottom = max(altitude.x, cameraPosition.y);
    float distance = max(altitude.y - bottom, 0.0) / max(sun.y, 0.02);
    vec3 origin = vec3(airShadowOrigin().x + (coordinate.x * 2.0 - 1.0) * AIR_SHADOW_EXTENT,
                       cameraPosition.y,
                       airShadowOrigin().y + (coordinate.y * 2.0 - 1.0) * AIR_SHADOW_EXTENT);
    float start = max((bottom - origin.y) / max(sun.y, 0.02), 0.0);
    float opticalDepth = 0.0;
    for (int index = 0; index < 64; index++) {
        float along = start + (float(index) + 0.5) * distance / 64.0;
        opticalDepth += cloudDensity(origin + sun * along, false) * distance / 64.0;
    }
    float transmission = exp(-opticalDepth * 0.04 * CLOUD_OPACITY);
    return mix(1.0, transmission, CLOUD_SHADOW_STRENGTH);
}

// 缓存存的是标量透射率，可由附件的线性过滤直接插值；深度比较仍在各自
// 的阴影函数中逐纹素完成。有效纹素中心钳制防止读入相邻天空/云环境区域。
float sampleAirCloudShadow(sampler2D field, vec3 world, vec3 sun) {
    vec2 projected = world.xz + sun.xz * (cameraPosition.y - world.y) / max(sun.y, 0.02);
    vec2 coordinate = (projected - airShadowOrigin()) / (2.0 * AIR_SHADOW_EXTENT) + 0.5;
    float edge = min(min(coordinate.x, coordinate.y), min(1.0 - coordinate.x, 1.0 - coordinate.y));
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0));
    vec2 pixel = clamp(coordinate, 0.5 / size, 1.0 - 0.5 / size) * size;
    vec2 uv = (vec2(size.x, 0.0) + pixel) / vec2(viewWidth, viewHeight);
    float shadow = texture(field, uv).a;
    return mix(1.0, shadow, smoothstep(0.0, 0.08, edge) * smoothstep(0.03, 0.12, sun.y));
}
#endif


bool airScatteringEnabled() {
#if ENABLE_SHADOWS == 0 || SIMPLE_DIMENSION != 0
    return false;
#else
    return isEyeInWater == 0 && AIR_SCATTER_STRENGTH > 0.0
        && SKY_HAZE > 0.0 && FOG_DENSITY > 0.0 && getSunHeight() > 0.0
        && weatherRainAmount() < 0.85;
#endif
}

// 相机朝向太阳时以气溶胶前向散射为主，较弱的分子项覆盖侧向观察。
float airScatteringPhase(float cosine) {
    const float g = 0.65;
    float mie = (1.0 - g * g)
              / (4.0 * PI * pow(1.0 + g * g - 2.0 * g * cosine, 1.5));
    float rayleigh = 3.0 * (1.0 + cosine * cosine) / (16.0 * PI);
    return mie * 0.85 + rayleigh * 0.15;
}

// 每个区间在两个深度点执行双线性阴影比较，同时过滤纵向覆盖和横向边缘。
// 相比原来的单点 PCF 增加一次查询，减少窄树枝跨过采样面时的跳变。
float airSunVisibility(vec3 ray, float start, float end) {
    float visibility = 0.0;
    for (int index = 0; index < 2; index++) {
        float distance = mix(start, end, (float(index) + 0.5) * 0.5);
        vec4 projected = shadowProjection * shadowModelView * vec4(ray * distance, 1.0);
        vec3 coordinate = distortShadow(projected.xyz / max(projected.w, EPSILON)) * 0.5 + 0.5;
        if (all(greaterThanEqual(coordinate, vec3(0.0)))
            && all(lessThanEqual(coordinate, vec3(1.0)))) {
            visibility += filteredShadowVisibility(shadowtex1, coordinate.xy, coordinate.z - 0.00015);
        }
    }
    return visibility * 0.5;
}

// 平稳的高度介质：云和几何决定光束运动，空气本身不叠加漂移的噪声条带。
float airParticleDensity(vec3 worldPosition) {
    return exp(-max(worldPosition.y - 64.0, 0.0) / 120.0);
}

// 固定距离区间（默认三十二个），遇到几何只截短最后一段，避免重排所有样本造成跳动。
// RGB 是沿途真实受光介质的预乘入散射，alpha 是同一介质的光学不透明度。
vec4 integrateAirScattering(vec2 uv, float sceneDistance, float densityModulation) {
    if (!airScatteringEnabled()) {
        return vec4(0.0);
    }
    vec3 sun = getSunDirWorld();
    if (dot(normalize(sunPosition), getLightDirView()) < 0.95) {
        return vec4(0.0);
    }
    vec3 ray = normalize(mat3(gbufferModelViewInverse) * screenToView(uv, 0.5));
    float range = min(64.0, shadowDistance * 0.8);
    float limit = min(sceneDistance, range);
    float lowSun = 1.0 - smoothstep(0.10, 0.65, sun.y);
    float coefficient = mix(0.0012, 0.0090, lowSun) * SKY_HAZE * FOG_DENSITY
                      * AIR_SCATTER_STRENGTH * smoothstep(0.0, 0.08, sun.y);
    // 区域浑浊度只作极低频的静态调节，光束内部不再叠加流动噪声。
    coefficient *= densityModulation;
    coefficient = min(coefficient, 0.012);
    // 表面使用 albedo * 日光 * NdotL，已隐含 Lambert 的 1/PI。
    // 相函数以每球面度归一化，介质计算须先恢复入射照度。
    // 方向光的体积贡献单独校准，显出遮挡光束而不继续提高全局消光。
    vec3 sunlight = getSunLightColor() * PI * 1.5
                  * (1.0 - smoothstep(0.15, 0.85, weatherRainAmount()));
    float cloudStart = 0.0;
    float cloudEnd = 0.0;
    float cloudNear = sampleAirCloudShadow(colortex3, cameraPosition, sun);
    float cloudFar = cloudNear;
    float phase = airScatteringPhase(dot(ray, sun));
    vec3 radiance = vec3(0.0);
    float transmission = 1.0;
    float previous = 0.0;
    for (int index = 0; index < AIR_SCATTER_STEPS; index++) {
        float u = float(index + 1) / float(AIR_SCATTER_STEPS);
        float next = min(u * u * range, limit);
        if (next <= previous) {
            break;
        }
        if (index - (index / 4) * 4 == 0) {
            cloudStart = cloudEnd;
            float group = float(index + 4) / float(AIR_SCATTER_STEPS);
            cloudEnd = group * group * range;
            cloudNear = cloudFar;
            cloudFar = sampleAirCloudShadow(colortex3, cameraPosition + ray * cloudEnd, sun);
        }
        float distance = (previous + next) * 0.5;
        vec3 relative = ray * distance;
        float density = airParticleDensity(cameraPosition + relative);
        density *= 1.0 - smoothstep(range * 0.75, range, distance);
        // 远景已有加载距离雾，在其接管前渐退近地面介质。
        density *= 1.0 - smoothstep(far * 0.40, far * 0.65, distance);
        float segment = exp(-coefficient * density * (next - previous));
        float visibility = airSunVisibility(ray, previous, next);
        float cloudPosition = clamp((distance - cloudStart) / max(cloudEnd - cloudStart, EPSILON), 0.0, 1.0);
        float cloudVisibility = mix(cloudNear, cloudFar, cloudPosition);
        radiance += transmission * sunlight * phase * visibility * cloudVisibility
                  * 0.90 * (1.0 - segment);
        transmission *= segment;
        previous = next;
    }
    return vec4(radiance, 1.0 - transmission);
}

#endif

/* Outdoor terrain mist. The companion's reserved atlas rows contain ground
 * height, habitat, native sky/block exposure and validity at four-block spacing.
 * No screen-derived height plane is used: missing chunks and indoor columns do
 * not seed fog. Header-relative coordinates survive OptiFine origin rebasing.
 */
#ifndef LIB_GROUND_FOG_GLSL
#define LIB_GROUND_FOG_GLSL




vec4 terrainFogHeader(float index) {
#ifdef WORLD_GPU_BACKEND
    return worldTerrainHeader(int(index));
#else
    return texture(companionAtlas, vec2(index + 0.5, 1.5) / companionAtlasSize());
#endif
}

bool hasTerrainAtmosphere() {
    return hasCompanionLighting() && abs(terrainFogHeader(0.0).w - 2718.0) < 0.5;
}

bool groundFogEnabled() {
#if SIMPLE_DIMENSION != 0
    return false;
#else
    return isEyeInWater == 0 && FOG_DENSITY > 0.0
        && (GROUND_FOG_STRENGTH > 0.0 || weatherRainAmount() * RAIN_FOG_STRENGTH > 0.001)
        && hasTerrainAtmosphere() && terrainFogHeader(1.0).w > 0.001;
#endif
}

vec4 terrainFogCell(vec2 cell, float side) {
#ifdef WORLD_GPU_BACKEND
    return worldTerrainColumn(ivec2(cell), 0);
#else
    vec2 size = companionAtlasSize();
    float index = 2.0 + cell.y * side + cell.x;
    return texture(companionAtlas, vec2(mod(index, size.x) + 0.5,
                     1.5 + floor(index / size.x)) / size);
#endif
}

vec4 decodeTerrainFogCell(vec4 cell) {
    float packedLight = floor(cell.b + 0.5);
    return vec4(cell.r, cell.g, floor(packedLight / 16.0) / 15.0, mod(packedLight, 16.0) / 15.0);
}

// Noise uses true-world modulo coordinates from the Mod, rather than the
// loader's rebased cameraPosition. Density and motion remain stable at +/-1000.
vec2 atmosphereWorldXZ(vec2 relative) {
    if (hasTerrainAtmosphere()) {
        return terrainFogHeader(1.0).yz + relative - terrainFogHeader(0.0).xy;
    }
    return cameraPosition.xz + relative;
}

vec4 sampleTerrainFog(vec2 relative, vec4 origin, vec4 metadata, out float coverage) {
    vec2 coordinate = (relative - origin.xy) / origin.z;
    vec2 border = min(coordinate, metadata.x - 1.0 - coordinate);
    coverage = smoothstep(0.0, 4.0, min(border.x, border.y)) * metadata.w;
    if (coverage <= 0.0) {
        return vec4(0.0);
    }
    vec2 lower = clamp(floor(coordinate), vec2(0.0), vec2(metadata.x - 2.0));
    vec2 f = clamp(coordinate - lower, 0.0, 1.0);
    vec4 a = terrainFogCell(lower, metadata.x);
    vec4 b = terrainFogCell(lower + vec2(1.0, 0.0), metadata.x);
    vec4 c = terrainFogCell(lower + vec2(0.0, 1.0), metadata.x);
    vec4 d = terrainFogCell(lower + vec2(1.0), metadata.x);
    coverage *= min(min(a.a, b.a), min(c.a, d.a));
    vec4 field = mix(mix(decodeTerrainFogCell(a), decodeTerrainFogCell(b), f.x),
                     mix(decodeTerrainFogCell(c), decodeTerrainFogCell(d), f.x), f.y);
    vec2 gradient = vec2(mix(b.r - a.r, d.r - c.r, f.y),
                         mix(c.r - a.r, d.r - b.r, f.x)) / origin.z;
    field.g = max(field.g, smoothstep(0.15, 1.0, length(gradient)) * 0.85);
    return field;
}

float terrainMistDensity(vec3 relative, vec4 field, float coverage, vec2 world) {
    float height = cameraPosition.y + relative.y - field.r;
    if (height < -0.5 || coverage <= 0.0 || field.g <= 0.0 || field.b <= 0.03) {
        return 0.0;
    }
#ifdef WORLD_GPU_BACKEND
    WorldPosition point = worldPosition(relative, cameraPosition);
    ivec2 column = point.block.xz - worldReadOrigin(colortex6, false).xz;
    vec4 roof = worldGroundColumn(column, 0);
    vec4 ceiling = worldGroundColumn(column, 1);
    float worldY = cameraPosition.y + relative.y;
    if ((roof.a > 0.5 && worldY < roof.r - 0.25)
        || (ceiling.a > 0.5 && ceiling.r > worldY + 0.1 && ceiling.r - worldY < 32.0)) return 0.0;
#endif
    float rainFog = weatherRainAmount() * clamp(rainBiome, 0.0, 1.0) * RAIN_FOG_STRENGTH;
    // 只用静态、低对比度的大尺度分布。二维噪声不再随时间平移，避免竖向雾墙摆动。
#ifdef WORLD_GPU_BACKEND
    float broad = atmosphereNoise2(world / 125.0, 8.0);
#else
    float broad = atmosphereNoise2(world / 128.0, 8.0);
#endif
    float dryLayer = GROUND_FOG_HEIGHT * mix(0.60, 1.25, broad);
    float rainLayer = clamp(GROUND_FOG_HEIGHT * 0.5, 2.0, 6.0);
    float layer = mix(dryLayer, rainLayer, clamp(rainFog, 0.0, 1.0));
    if (height >= layer * 3.0) {
        return 0.0;
    }
    // 雨量增加密度，不再把雾层抬到树冠；离地数个方块后连续衰减。
    float vertical = exp(-max(height, 0.0) / layer)
                   * smoothstep(-0.5, 1.0, height)
                   * (1.0 - smoothstep(layer * 1.5, layer * 3.0, height));
    float outdoors = smoothstep(0.03, 0.35, field.b);
    float weather = (0.22 + atmosphereTwilight() * 0.8 + getNightFactor() * 0.38)
                  * GROUND_FOG_STRENGTH + rainFog * 0.65;
    return vertical * outdoors * field.g * coverage * mix(0.82, 1.0, broad)
         * weather * FOG_DENSITY * 0.018;
}
#endif


bool localAtmosphereEnabled() {
    if (isEyeInWater != 0 || FOG_DENSITY <= 0.0) {
        return false;
    }
#if SIMPLE_DIMENSION == -1
    return NETHER_ATMOSPHERE > 0.0;
#elif SIMPLE_DIMENSION == 1
    return END_ATMOSPHERE > 0.0;
#else
    return groundFogEnabled();
#endif
}

vec4 mergeAtmosphericMedia(vec4 first, vec4 second) {
    if (first.a <= 0.00001) {
        return second;
    }
    if (second.a <= 0.00001) {
        return first;
    }
    float a = -log(max(1.0 - first.a, 0.00001));
    float b = -log(max(1.0 - second.a, 0.00001));
    float opacity = 1.0 - exp(-a - b);
    vec3 source = (first.rgb * a / first.a + second.rgb * b / second.a) / (a + b);
    return vec4(source * opacity, opacity);
}

vec4 integrateLocalAtmosphere(vec2 uv, float sceneDistance) {
    if (!localAtmosphereEnabled()) {
        return vec4(0.0);
    }
    vec3 rayView = normalize(screenToView(uv, 0.5));
    vec3 ray = normalize(mat3(gbufferModelViewInverse) * rayView);
    float range = min(96.0, far * 0.80);
    float limit = min(sceneDistance, range);
    vec3 radiance = vec3(0.0);
    float transmission = 1.0;
    float previous = 0.0;
    vec3 localGlow = vec3(0.0);
    vec4 terrainOrigin = vec4(0.0);
    vec4 terrainMetadata = vec4(0.0);
    vec2 noiseOrigin = cameraPosition.xz;
    if (hasTerrainAtmosphere()) {
        terrainOrigin = terrainFogHeader(0.0);
        terrainMetadata = terrainFogHeader(1.0);
        noiseOrigin = terrainMetadata.yz - terrainOrigin.xy;
    }
    vec3 solar = getSunLightColor() + getMoonLightColor();
    // 阴雨由天空漫射照亮低层雾，云影不再被放大成贯穿视野的明暗光柱。
    solar *= 1.0 - smoothstep(0.15, 0.85, weatherRainAmount());
    float phase = airScatteringPhase(dot(ray, normalize(mat3(gbufferModelViewInverse) * getLightDirView())));
    float directVisibility = 1.0;
    float minimumTransmission = mix(0.45, 0.60,
        clamp(weatherRainAmount() * RAIN_FOG_STRENGTH, 0.0, 1.0));
    for (int index = 0; index < ATMOSPHERE_STEPS; index++) {
        float u = float(index + 1) / float(ATMOSPHERE_STEPS);
        float next = min(u * u * range, limit);
        if (next <= previous || transmission <= minimumTransmission + 0.001) {
            break;
        }
        float distance = (previous + next) * 0.5;
        vec3 relative = ray * distance;
        float density;
        vec3 source;
#if SIMPLE_DIMENSION == 0
        float coverage;
        vec4 field = sampleTerrainFog(relative.xz, terrainOrigin, terrainMetadata, coverage);
        density = terrainMistDensity(relative, field, coverage, noiseOrigin + relative.xz);
        if (density <= 0.000001) {
            previous = next;
            continue;
        }
        vec3 sky = mix(toLinearSpace(skyColor) * 0.40, vec3(0.018, 0.030, 0.050), getNightFactor());
        sky = mix(sky, vec3(luma(sky)) * vec3(0.92, 0.96, 1.0), weatherRainAmount());
        source = sky + twilightIrradiance(vec3(0.0, 1.0, 0.0)) * 0.55;
        if (any(greaterThan(solar, vec3(0.0)))) {
#if ENABLE_SHADOWS == 1
            if (index - (index / 2) * 2 == 0) {
                directVisibility = airSunVisibility(ray, previous, next);
                directVisibility *= sampleAirCloudShadow(colortex3, cameraPosition + relative,
                    normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
            }
#endif
            source += solar * directVisibility * phase * PI * 1.5;
        }
        float block = 4.0 * blockLightAttenuation(field.a) * BLOCK_LIGHT_STRENGTH;
        if (block > 0.001) {
            vec3 tint = toLinearSpace(vec3(1.0, 0.65, 0.32));
#if ENABLE_COLOURED_LIGHTING == 1
            vec3 ground = cameraPosition + vec3(relative.x, field.r + 2.0 - cameraPosition.y, relative.z);
            vec4 hue = companionHue(ground - companionHueOrigin);
            if (hue.a > 0.5) {
                tint = hue.rgb;
            }
#endif
            float height = max(cameraPosition.y + relative.y - field.r, 0.0);
            source += tint * block * exp(-height / 10.0) * 0.35;
        }
#else
        vec2 worldXZ = noiseOrigin + relative.xz;
        float worldY = cameraPosition.y + relative.y;
        float clock = frameTimeCounter * TAU / 3600.0;
        vec2 drift = vec2(sin(clock * 3.0), cos(clock * 3.0)) * 0.6;
        float pockets = atmosphereNoise2(worldXZ / 64.0 + vec2(worldY * 0.018) + drift, 16.0);
#if SIMPLE_DIMENSION == -1
        density = NETHER_ATMOSPHERE * mix(0.0007, 0.0032, pockets) * FOG_DENSITY;
        vec3 lower = mix(dimensionFogColor(), vec3(0.16, 0.035, 0.009), 0.12);
        source = mix(lower, dimensionAmbient(vec3(0.0, 1.0, 0.0)), smoothstep(25.0, 90.0, worldY));
#else
        density = END_ATMOSPHERE * mix(0.0004, 0.0018, pockets) * FOG_DENSITY;
        source = mix(vec3(0.045, 0.020, 0.075), vec3(0.020, 0.060, 0.080), pockets);
#endif
        if (index - (index / 2) * 2 == 0) {
            localGlow = companionIndirect(rayView * distance, -rayView);
        }
        source += localGlow * 0.35;
#endif
        density *= smoothstep(1.5, 6.0, distance)
                 * (1.0 - smoothstep(far * 0.55, far * 0.80, distance));
        float available = log(max(transmission, 0.00001) / minimumTransmission);
        float opticalDepth = min(density * (next - previous), max(available, 0.0));
        float segment = exp(-opticalDepth);
        radiance += transmission * source * (1.0 - segment);
        transmission *= segment;
        previous = next;
    }
    return vec4(radiance, 1.0 - transmission);
}
#endif



/* Depth-aware reconstruction of the reduced air/cloud field. Callers declare
 * the common depth, water and volume samplers before including this module. */
#ifndef LIB_VOLUME_RECONSTRUCTION_GLSL
#define LIB_VOLUME_RECONSTRUCTION_GLSL
// Neighbour depths reject volume samples from the other side of a foreground
// silhouette. No temporal history is needed, so captures remain deterministic.
vec4 upsampleClouds(vec2 uv, float distance) {
    vec3 ray = getCloudRayWorld(uv);
    float entry;
    float exit;
    if (isEyeInWater == 1 || (!airScatteringEnabled() && !localAtmosphereEnabled()
        && !cloudRayInterval(cameraPosition, ray, distance, entry, exit))) {
        return vec4(0.0);
    }
    vec2 size = volumeSize();
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    vec4 sum = vec4(0.0);
    float total = 0.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 sampleUv = clamp((base + vec2(float(x), float(y)) + 0.5) / size,
                                  0.5 / size, 1.0 - 0.5 / size);
            float depth = texture(depthtex1, sampleUv).r;
            float neighbourDistance = depth < 0.999999 ? length(screenToView(sampleUv, depth)) : CLOUD_DISTANCE;
            float surface = readWaterSurface(colortex9, colortex1, sampleUv).a;
            if (surface > 0.001) {
                neighbourDistance = min(neighbourDistance, length(waterSurfacePosition(sampleUv, surface)));
            }
            float spatial = (x == 0 ? 1.0 - fraction.x : fraction.x)
                          * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = spatial * exp(-abs(neighbourDistance - distance) / max(distance * 0.10, 0.5));
            sum += texture(colortex4, sampleUv * size / vec2(viewWidth, viewHeight)) * weight;
            total += weight;
        }
    }
    return total > 0.00001 ? sum / total : vec4(0.0);
}

#endif


void main() {
    vec2 screenCoord = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    float depth = texture(depthtex0, screenCoord).r;
    // 入水状态是整帧常量。水下合成本身负责天空、深度与水面采样，无需在此
    // 预先计算随后立即被覆盖的天空/水面反射，也不读取空气体积场。
    if (isEyeInWater == 1) {
        fullOut0 = vec4(applyUnderwaterOptics(screenCoord, depth), 1.0);
        return;
    }
    vec4 scene = texture(colortex0, screenCoord);
    vec3 color = scene.rgb;
    float backgroundTransmission = rainStrength > 0.001 ? clamp(scene.a, 0.0, 1.0) : 1.0;
    float sceneDistance = depth < 0.999999 ? length(screenToView(screenCoord, depth)) : CLOUD_DISTANCE;
    vec4 waterSurface = readWaterSurface(colortex9, colortex1, screenCoord);
    float waterDepth = waterSurface.a;
    // 在水面分支前求法线变化率，保证轮廓附近的屏幕导数也有定义。
    vec3 waterNormal = decodeWaterNormal(waterSurface.xy);
    vec3 normalDx = dFdx(waterNormal);
    vec3 normalDy = dFdy(waterNormal);
    float waterCoverage = step(0.001, waterDepth);
    float sameX = 1.0 - step(0.5, abs(dFdx(waterCoverage)));
    float sameY = 1.0 - step(0.5, abs(dFdy(waterCoverage)));
    float normalVariance = 0.15 * (dot(normalDx, normalDx) * sameX + dot(normalDy, normalDy) * sameY);
    if (waterDepth > 0.001 && isEyeInWater == 0) {
        vec3 waterPosition = waterSurfacePosition(screenCoord, waterDepth);
        sceneDistance = min(sceneDistance, length(waterPosition));
        vec4 transparentLayer = texture(colortex2, screenCoord);
        bool inFront = transparentLayerInFront(-screenToView(screenCoord, depth).z,
                                               waterDepth, transparentLayer.a);
        color = applyWaterReflection(color, screenCoord, normalVariance);
        if (inFront) {
            color = applyTransparentLayer(color, transparentLayer);
        }
#if DEBUG_VIEW != 0
        backgroundTransmission = 1.0;
#endif
    } else if (backgroundTransmission >= 0.99999) {
        // 天空已经在 deferred1 填好；雨丝覆盖处保留混合结果，避免再次覆盖雨幕。
        color = fillSkyBackground(color, screenCoord, depth);
    }
    if (depth < 0.999999 || waterDepth > 0.001) {
        // 雨丝自身按距离淡出，雾色差只修正仍可见的背景，避免远处雨丝发黄。
        color = correctSkyFog(color, screenCoord, sceneDistance, backgroundTransmission);
    }
#ifndef WORLD_BASE_OPTICS
    // Glass transmits the medium behind it. Opaque depth guides all air fields;
    // the explicit water interface still clips them at the air/water boundary.
    float opaqueDepth = texture(depthtex1, screenCoord).r;
    float volumeDistance = opaqueDepth < 0.999999
        ? length(screenToView(screenCoord, opaqueDepth)) : CLOUD_DISTANCE;
    if (waterDepth > 0.001) {
        volumeDistance = min(volumeDistance, length(waterSurfacePosition(screenCoord, waterDepth)));
    }
    vec4 cloud = upsampleClouds(screenCoord, volumeDistance);
    color = cloud.rgb + color * (1.0 - cloud.a);
#endif
#if DEBUG_VIEW == 0
    // 天气只在近处光学处理完成后叠加一次，云背景与无云背景使用同一雨层。
    color = applyRainOverlay(color, texture(colortex1, screenCoord), waterDepth > 0.001);
#endif
    fullOut0 = vec4(color, 1.0);
}

