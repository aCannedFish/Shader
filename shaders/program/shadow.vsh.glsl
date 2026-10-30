/* Shadow vertices atomically publish a compact material per block. Priority is
 * deterministic: emitters, opaque geometry, then transmission. The second
 * fixed-size C5 image is detached from all raster attachments. Native shadow
 * drawing therefore cannot overwrite it, and front-end water data uses C9.
 */
#ifndef SIMPLE_CONVENTIONAL_VOXEL_GLSL
#define SIMPLE_CONVENTIONAL_VOXEL_GLSL
/* Compact local lighting. Fixed-size C5 is an image-only integer voxel store,
 * C10 holds three source identities, C11 their cached RGB transmission,
 * and C8 low-energy diffuse radiance. Direct RGB contributions remain separate
 * until the material consumer adds their independently shadowed radiance.
 */
#ifndef SIMPLE_CONVENTIONAL_LPV_GLSL
#define SIMPLE_CONVENTIONAL_LPV_GLSL
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


#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
// 任一原生模型顶点不在立方体角点时，整格遮挡证据即失效；partial投票优先。
// 使用实际几何属性，资源包改变模型后无需按方块名称维护分类表。
void lpvCaptureGeometry(vec3 centre, vec3 midBlock) {
    if (renderStage != 8 && renderStage != 9 && renderStage != 16) return;
    ivec3 cell = ivec3(floor(centre + 0.001)) - lpvOrigin(cameraPosition);
    if (!lpvInside(cell)) return;
    bool corner = all(lessThan(abs(abs(midBlock) - vec3(32.0)), vec3(0.1)));
    ivec3 shape = lpvShape();
    int index = lpvIndex(cell) + shape.x * shape.y * shape.z;
    int width = imageSize(colorimg5).x;
    imageAtomicMax(colorimg5, ivec2(index % width, index / width), corner ? 1u : 2u);
}

uint lpvPackMaterial(vec3 colour, uint kind, int emission, bool solid) {
    uvec3 rgb = uvec3(round(clamp(colour, 0.0, 1.0) * 255.0));
    return (kind << 30u) | (uint(emission) << 24u) | (uint(solid) << 28u)
        | rgb.r | (rgb.g << 8u) | (rgb.b << 16u);
}

uint lpvVoxelMaterial(int id) {
    if (id == 6000) return lpvPackMaterial(vec3(1.0, 0.46, 0.12), LPV_EMITTER, 15, true);
    if (id == 6001) return lpvPackMaterial(vec3(0.10, 0.65, 1.0), LPV_EMITTER, 10, false);
    if (id == 6002) return lpvPackMaterial(vec3(1.0, 0.05, 0.01), LPV_EMITTER, 7, false);
    if (id == 6003) return lpvPackMaterial(vec3(0.55, 0.95, 0.82), LPV_EMITTER, 15, true);
    if (id == 6004) return lpvPackMaterial(vec3(0.92, 0.85, 1.0), LPV_EMITTER, 14, false);
    if (id == 6005) return lpvPackMaterial(vec3(0.48, 1.0, 0.35), LPV_EMITTER, 15, true);
    if (id == 6006) return lpvPackMaterial(vec3(1.0, 0.58, 0.90), LPV_EMITTER, 15, true);
    if (id == 6007) return lpvPackMaterial(vec3(0.68, 0.20, 1.0), LPV_EMITTER, 10, true);
    if (id == 6008) return lpvPackMaterial(vec3(1.0, 0.35, 0.08), LPV_EMITTER, 15, true);
    if (id == 6009) return lpvPackMaterial(vec3(0.68, 0.20, 1.0), LPV_EMITTER, 5, false);
    if (id == 6010 || id == 101) return lpvPackMaterial(vec3(1.0, 0.46, 0.12), LPV_EMITTER, 14, false);
    if (id == 102) return lpvPackMaterial(vec3(0.85, 0.80, 1.0), LPV_EMITTER, 14, false);
    if (id == 100 || id == 110) return lpvPackMaterial(vec3(0.90, 0.95, 1.0), LPV_GLASS, 0, false);
    if (id >= 200 && id < 300) return lpvPackMaterial(vec3(0.85, 0.95, 0.75), LPV_GLASS, 0, false);
    return lpvPackMaterial(vec3(0.0), LPV_SOLID, 0, true);
}

void lpvCaptureVertex(vec3 centre, int id) {
    // J9 interleaves ENTITIES=10, BLOCK_ENTITIES=11 and HAND_SOLID=15 between
    // terrain passes. Their vertices do not carry a valid terrain at_midBlock
    // or material attribute; accepting them creates moving solid/emitter cells.
    if (renderStage != 8 && renderStage != 9 && renderStage != 16) return;
    ivec3 cell = ivec3(floor(centre + 0.001)) - lpvOrigin(cameraPosition);
    if (!lpvInside(cell)) return;
    int index = lpvIndex(cell);
    ivec2 size = imageSize(colorimg5);
    imageAtomicMax(colorimg5, ivec2(index % size.x, index / size.x), lpvVoxelMaterial(id));
}

// Diffuse GI needs the terrain's linear albedo and native skylight. The four
// emission bits are unused for ordinary solids and hold their sky level instead.
// Quantized atlas colours avoid texture-edge and vertex-order noise in the field.
void lpvCaptureSurface(vec3 centre, int id, vec3 albedo, float skyLevel) {
    if (renderStage != 8 && renderStage != 9 && renderStage != 16) return;
    ivec3 cell = ivec3(floor(centre + 0.001)) - lpvOrigin(cameraPosition);
    if (!lpvInside(cell)) return;
    uint material = lpvVoxelMaterial(id);
    if (lpvKind(material) == LPV_SOLID) {
        vec3 diffuse = floor(clamp(albedo, 0.0, 0.85) * 31.0 + 0.5) / 31.0;
        material = lpvPackMaterial(diffuse, LPV_SOLID, int(round(skyLevel * 15.0)), true);
    }
    int index = lpvIndex(cell);
    int width = imageSize(colorimg5).x;
    imageAtomicMax(colorimg5, ivec2(index % width, index / width), material);
}
#endif
#endif

uniform sampler2D gtexture;
in vec2 mc_midTexCoord;
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
in vec3 mc_Entity;

/*
================================================================================
 shadow.vsh —— 阴影贴图顶点着色器
================================================================================
 这个程序【不渲染任何颜色】，它只做一件事：
 站在太阳的位置，把整个世界的深度信息烤进一张贴图。

 渲染过程：
   1. OptiFine 把场景里所有会投影的几何体重新送一遍进来；
   2. modelViewMatrix 把当前区块/实体从模型空间转到阴影视图空间，
      projectionMatrix 再投影；
   3. 施加和 gbuffers 完全一样的畸变；
   4. GPU 自动把深度写进 shadowMap。

 和 gbuffers_terrain.vsh 对照着看会发现：公式一模一样，
 只是把 gbufferModelView/gbufferProjection 换成了 shadow 系列。
 这正是"阴影贴图 = 从光源视角再渲染一遍"的字面含义。

 注意这里【没有】gbufferModelViewInverse：阴影绘制时的内置矩阵
 已经包含了当前几何体的变换，无须重新还原玩家视图空间坐标。

 调试技巧：把 settings.glsl 里 shadowDistance 调小到 32，
 就能在游戏里看清阴影贴图的覆盖范围 —— 超出范围的地方没有阴影。
================================================================================
*/

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

/*
 * 植被顶点风摆。地形和阴影共用世界坐标、时间、分类与位移函数。
 * 叶片采用连续空间场以保持相邻方块接缝；草/花/作物以根部为固定支点。
 * 两格植物的上下部分使用同一根部、相位和高度曲线。
 */
#ifndef LIB_FOLIAGE_WIND_GLSL
#define LIB_FOLIAGE_WIND_GLSL





const float WIND_LEAVES_ID = 200.0;
const float WIND_PLANT_ID = 201.0;
const float WIND_TALL_LOWER_ID = 202.0;
const float WIND_TALL_UPPER_ID = 203.0;
const float WIND_CROP_ID = 204.0;

bool hasFoliageWind(float material) {
    return material >= 199.5 && material <= 204.5;
}

// 有界哈希只作用于植株根部，相邻面及双格植物不会得到不同的随机相位。
float plantWindHash(vec3 root) {
    vec3 value = fract(root * vec3(0.1031, 0.1030, 0.0973));
    value += dot(value, value.yzx + 33.33);
    return fract((value.x + value.y) * value.z);
}

// 坐标在变形前计算；顶点到方块中心的属性精度为 1/64 方块。
vec3 foliageRoot(vec3 blockCenter, float material) {
    vec3 root = floor(blockCenter + 0.001);
    root.xz += 0.5;
    if (abs(material - WIND_TALL_UPPER_ID) < 0.5) {
        root.y -= 1.0;
    }
    return root;
}

float foliageWindTime() {
    return frameTimeCounter * WIND_SPEED;
}

// 大尺度风向与缓慢阵风共用；雨天适度增强，细节运动的周期彼此错开。
vec3 foliageWindOffset(vec3 worldPosition, vec3 root, float material) {
#if ENABLE_FOLIAGE_WIND == 0
    return vec3(0.0);
#else
    if (!hasFoliageWind(material) || WIND_STRENGTH <= 0.0) {
        return vec3(0.0);
    }
    float time = foliageWindTime();
    vec2 direction = normalize(vec2(0.92, 0.39));
    vec2 crosswind = vec2(-direction.y, direction.x);
    float weather = 1.0 + rainStrength * 0.35;
    if (abs(material - WIND_LEAVES_ID) < 0.5) {
        // 对共享顶点使用同一位置函数，避免叶团分裂成独立摇晃的小方块。
        float phase = dot(worldPosition, vec3(0.16, 0.11, 0.13));
        float broad = sin(phase - time * 1.35) * 0.72;
        float flutter = sin(phase * 2.7 + time * 2.10) * 0.28;
        float sideways = sin(phase * 1.4 - time * 1.73 + 1.7) * 0.30;
        vec2 horizontal = direction * (broad + flutter) + crosswind * sideways;
        float vertical = sin(phase * 1.8 + time * 1.60) * 0.18;
        return vec3(horizontal.x, vertical, horizontal.y)
             * LEAF_SWAY_STRENGTH * WIND_STRENGTH * weather;
    }

    bool tall = abs(material - WIND_TALL_LOWER_ID) < 0.5
             || abs(material - WIND_TALL_UPPER_ID) < 0.5;
    float span = tall ? 2.0 : 1.0;
    float height = max(worldPosition.y - root.y, 0.0);
    float bend = clamp(height / span, 0.0, 1.0);
    bend *= bend;
    float phase = plantWindHash(root) * (2.0 * PI) + dot(root.xz, vec2(0.055, 0.081));
    float gust = 0.70 + 0.30 * sin(dot(root.xz, vec2(0.037, -0.026)) - time * 0.37);
    float sway = sin(time * 1.55 + phase) * 0.72 + sin(time * 2.83 + phase * 1.37) * 0.28;
    float side = sin(time * 1.19 + phase * 1.73) * 0.22;
    float cropScale = abs(material - WIND_CROP_ID) < 0.5 ? 0.75 : 1.0;
    vec2 horizontal = (direction * sway + crosswind * side) * gust * bend * span
                    * PLANT_SWAY_STRENGTH * WIND_STRENGTH * cropScale * weather;
    // 小角度弯曲的高度补偿，根部高度及水平坐标均严格保持不动。
    float vertical = -0.5 * dot(horizontal, horizontal) / max(height, 0.1);
    return vec3(horizontal.x, vertical, horizontal.y);
#endif
}

// 叶片只依赖一个空间相位，可直接求位移雅可比；植株只随根部高度变化，
// 复用已经求得的位移计算高度差分。两者都不再重复四次完整的风场与哈希。
vec3 foliageWindNormal(vec3 worldPosition, vec3 root, float material,
                       vec3 normalWorld, vec3 displacement) {
#if ENABLE_FOLIAGE_WIND == 0
    return normalWorld;
#else
    if (!hasFoliageWind(material) || WIND_STRENGTH <= 0.0) {
        return normalWorld;
    }
    vec3 derivative;
    vec3 gradient;
    if (abs(material - WIND_LEAVES_ID) < 0.5) {
        float time = foliageWindTime();
        float phase = dot(worldPosition, vec3(0.16, 0.11, 0.13));
        vec2 direction = normalize(vec2(0.92, 0.39));
        vec2 crosswind = vec2(-direction.y, direction.x);
        float along = cos(phase - time * 1.35) * 0.72
                    + cos(phase * 2.7 + time * 2.10) * (0.28 * 2.7);
        float side = cos(phase * 1.4 - time * 1.73 + 1.7) * (0.30 * 1.4);
        vec2 horizontal = direction * along + crosswind * side;
        float vertical = cos(phase * 1.8 + time * 1.60) * (0.18 * 1.8);
        derivative = vec3(horizontal.x, vertical, horizontal.y)
                   * LEAF_SWAY_STRENGTH * WIND_STRENGTH * (1.0 + rainStrength * 0.35);
        gradient = vec3(0.16, 0.11, 0.13);
    } else {
        bool tall = abs(material - WIND_TALL_LOWER_ID) < 0.5
                 || abs(material - WIND_TALL_UPPER_ID) < 0.5;
        float span = tall ? 2.0 : 1.0;
        float height = max(worldPosition.y - root.y, 0.0);
        float bend = clamp(height / span, 0.0, 1.0);
        if (bend <= 0.0001) {
            return normalWorld;
        }
        // 保留根部、顶端限幅及高度补偿的原有边界行为；这里只做标量差分，
        // 不重复依赖根部哈希和时间的三角函数。
        const float epsilon = 0.02;
        float upper = square(clamp((height + epsilon) / span, 0.0, 1.0)) / square(bend);
        float lower = square(clamp((height - epsilon) / span, 0.0, 1.0)) / square(bend);
        vec2 horizontal = displacement.xz * (upper - lower) / (2.0 * epsilon);
        float squared = dot(displacement.xz, displacement.xz);
        float upperY = -0.5 * squared * upper * upper / max(height + epsilon, 0.1);
        float lowerY = -0.5 * squared * lower * lower / max(height - epsilon, 0.1);
        derivative = vec3(horizontal.x, (upperY - lowerY) / (2.0 * epsilon), horizontal.y);
        gradient = vec3(0.0, 1.0, 0.0);
    }
    vec3 reference = abs(normalWorld.y) < 0.95 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(reference, normalWorld));
    vec3 bitangent = cross(normalWorld, tangent);
    vec3 deformedTangent = tangent + derivative * dot(gradient, tangent);
    vec3 deformedBitangent = bitangent + derivative * dot(gradient, bitangent);
    return safeNormalize(cross(deformedTangent, deformedBitangent), normalWorld);
#endif
}

// 独立探针或其它调用方未缓存位移时仍可使用原接口。
vec3 foliageWindNormal(vec3 worldPosition, vec3 root, float material, vec3 normalWorld) {
    return foliageWindNormal(worldPosition, root, material, normalWorld,
                             foliageWindOffset(worldPosition, root, material));
}

#endif



// 植被只对已映射的方块生效，实体和普通方块保留原来的位置。

in vec3 at_midBlock;

SIMPLE_VARYING vec2 vTexCoord;
SIMPLE_VARYING vec4 vColor;
SIMPLE_VARYING vec3 vShadowPosition;
// 投影体类别：0 不透明，1 发光方块，2 透光玻璃，3 水，4 薄植被。
SIMPLE_VARYING float vCaster;

void main() {
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
    vec3 lpvCentre = (shadowModelViewInverse * modelViewMatrix
        * vec4(vaPosition + modelOffset, 1.0)).xyz + cameraPosition + at_midBlock / 64.0;
    lpvCaptureGeometry(lpvCentre, at_midBlock);
#if GI_QUALITY > 0
    vec3 lpvAlbedo = textureLod(gtexture, mc_midTexCoord, 2.0).rgb * vaColor.rgb;
    lpvAlbedo = pow(max(lpvAlbedo, vec3(0.0)), vec3(2.2));
    lpvCaptureSurface(lpvCentre, int(round(mc_Entity.x)), lpvAlbedo,
        clamp(float(vaUV2.y) / 240.0, 0.0, 1.0));
#else
    lpvCaptureVertex(lpvCentre, int(round(mc_Entity.x)));
#endif
#endif

    float alias = mc_Entity.x;
    if (alias >= 6000.0 && alias <= 6010.0) {
        alias = alias == 6000.0 || alias == 6003.0 || alias == 6010.0 ? 101.0 : 102.0;
    }
    vec2 legacyEntity = vec2(alias, mc_Entity.y);
    // 1. 世界空间 -> 太阳的裁剪空间
    vec3 position = vec4(vaPosition + modelOffset, 1.0).xyz;
    vCaster = abs(legacyEntity.x - 101.0) < 0.5 || abs(legacyEntity.x - 102.0) < 0.5 ? 1.0
            : abs(legacyEntity.x - 110.0) < 0.5 ? 2.0
            : abs(legacyEntity.x - 100.0) < 0.5 ? 3.0
            : hasFoliageWind(legacyEntity.x) ? 4.0 : 0.0;
    if (hasFoliageWind(legacyEntity.x)) {
        vec3 shadowViewPosition = (modelViewMatrix * vec4(vaPosition + modelOffset, 1.0)).xyz;
        vec3 worldPosition = (shadowModelViewInverse * vec4(shadowViewPosition, 1.0)).xyz
                           + cameraPosition;
        vec3 blockCenter = worldPosition + at_midBlock / 64.0;
        vec3 root = foliageRoot(blockCenter, legacyEntity.x);
        position += foliageWindOffset(worldPosition, root, legacyEntity.x);
    }
    vec4 shadowClipPos = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    // 保留原始三角形平面，片元阶段在真实阴影纹素中心重新求深度。
    vShadowPosition = shadowClipPos.xyz / shadowClipPos.w;

    // 2. 畸变。必须和 gbuffers 用的完全一致，否则采样位置会对不上。
    shadowClipPos.xyz = distortShadow(shadowClipPos.xyz);

    // 3. 交给 GPU 光栅化并写深度
    gl_Position = shadowClipPos;

    // 4. 透传贴图坐标与顶点颜色，供片元着色器做 alpha 测试
    vTexCoord = vaUV0;
    vColor = vaColor;
    if (vColor.a < 0.1) {
        vColor.a = 1.0;
    }
}

