#define SIMPLE_VARYING in
layout(location=0) out vec4 fullOut0;
layout(location=1) out vec4 fullOut1;
layout(location=2) out vec4 fullOut2;
layout(location=3) out vec4 fullOut3;
layout(location=4) out vec4 fullOut4;
/* 岸线与水底折角的半分辨率种子。C14的材质参数已在deferred1消费，
 * 此后复用其左下区域；只从原生水面覆盖和不透明深度检测边界。
 */
/* RENDERTARGETS: 14 */
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

uniform sampler2D colortex9;
uniform sampler2D depthtex1;

vec2 boundaryUv(vec2 pixel) {
    vec2 size = vec2(viewWidth, viewHeight);
    return (clamp(pixel, vec2(0.0), size - 1.0) + 0.5) / size;
}

// 投影深度在平面内部线性变化；二阶差分检测台阶、轮廓和朝向突变。
bool boundaryCrease(float minus, float centre, float plus) {
    float first = centre - minus;
    float second = plus - centre;
    return abs(first - second) > max(0.0000003, min(abs(first), abs(second)) * 0.3);
}

bool waterBoundaryAt(vec2 pixel) {
    vec2 uv = boundaryUv(pixel);
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    float coverage = step(0.5, texture(colortex9, uv).a);
    float left = step(0.5, texture(colortex9, boundaryUv(pixel - vec2(1.0, 0.0))).a);
    float right = step(0.5, texture(colortex9, boundaryUv(pixel + vec2(1.0, 0.0))).a);
    float down = step(0.5, texture(colortex9, boundaryUv(pixel - vec2(0.0, 1.0))).a);
    float up = step(0.5, texture(colortex9, boundaryUv(pixel + vec2(0.0, 1.0))).a);
    if (left != coverage || right != coverage || down != coverage || up != coverage) return true;
    if (coverage < 0.5) return false;
    if (any(lessThan(pixel, vec2(1.0)))
        || any(greaterThanEqual(pixel, vec2(viewWidth, viewHeight) - 1.0))) return true;
    float depth = texture(depthtex1, uv).r;
    return boundaryCrease(texture(depthtex1, uv - vec2(texel.x, 0.0)).r,
            depth, texture(depthtex1, uv + vec2(texel.x, 0.0)).r)
        || boundaryCrease(texture(depthtex1, uv - vec2(0.0, texel.y)).r,
            depth, texture(depthtex1, uv + vec2(0.0, texel.y)).r);
}

void main() {
    fullOut0 = vec4(-1.0, -1.0, 0.0, 0.0);
    vec2 size = vec2(viewWidth, viewHeight);
    if (isEyeInWater != 0 || WATER_REFRACTION_STRENGTH <= 0.0
        || any(greaterThanEqual(gl_FragCoord.xy, ceil(size * 0.5)))) return;
    vec2 base = floor(gl_FragCoord.xy) * 2.0;
    bool edge = false;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            edge = waterBoundaryAt(base + vec2(float(x), float(y))) || edge;
        }
    }
    if (edge) fullOut0 = vec4(gl_FragCoord.xy, 0.0, 1.0);
}

