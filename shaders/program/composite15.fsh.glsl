#define SIMPLE_VARYING in
layout(location=0) out vec4 fullOut0;
layout(location=1) out vec4 fullOut1;
layout(location=2) out vec4 fullOut2;
layout(location=3) out vec4 fullOut3;
layout(location=4) out vec4 fullOut4;
// 相机介质历史更新。
/* 保存下一帧使用的单纹素介质历史；从原生水面附件估计，不接收外部世界数据。 */
/* RENDERTARGETS: 13 */
/* 水面光学与波浪工具。共享 Fresnel、八面体法线编码和连续波浪高度场。
 * 三组正弦分量使用绝对世界坐标保持区块接缝连续，正弦差公式直接求差分法线。
 */
#ifndef LIB_WATER_GLSL
#define LIB_WATER_GLSL

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




/*
 * Minecraft 光照贴图的连续采样与光源分离。
 * 在相邻等级的纹素中心手动插值，避免加载器的最近邻采样造成亮度台阶。
 * 方块光从无天光的行中提取，保留原版传播和遮挡，同时避免白天天光饱和将火把光压掉。
 */
#ifndef LIB_LIGHTMAP_GLSL
#define LIB_LIGHTMAP_GLSL


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

uniform sampler2D colortex9;
uniform sampler2D colortex1;

void main() {
    vec2 medium = isEyeInWater == 1 ? estimateWaterMedium(colortex9, colortex1) : vec2(0.0);
    fullOut0 = vec4(medium, float(frameCounter), isEyeInWater == 1 ? 4183.0 : 0.0);
}

