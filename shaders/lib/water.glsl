/* 水面光学与波浪工具。共享 Fresnel、八面体法线编码和连续波浪高度场。
 * 三组正弦分量使用绝对世界坐标保持区块接缝连续，正弦差公式直接求差分法线。
 */
#ifndef LIB_WATER_GLSL
#define LIB_WATER_GLSL

#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"
#include "companion_lighting.glsl"
#ifdef WORLD_PACKED_WATER
#include "/lib/world/water_packet.glsl"
#endif


// block.properties 将水映射到此 ID，避免玻璃也产生波浪。
const float WATER_BLOCK_ID = 100.0;

// 水面几何与参数各自以 alpha=1 标记有效片元，玻璃以 alpha=0 保留这些数据。
// 返回既有逻辑使用的布局：八面体法线 RG、天空可见度 B、线性视图深度 A。
vec4 readWaterSurface(sampler2D geometry, sampler2D parameters, vec2 uv) {
#ifdef WORLD_PACKED_WATER
    WaterSurfacePacket packedSurface = readWaterPacket(geometry, uv);
    if (packedSurface.coverage < 0.5) return vec4(0.0);
    return vec4(packedSurface.normal, texture2D(parameters, uv).r, packedSurface.depth);
#else
    vec4 surface = texture2D(geometry, uv);
    if (surface.a < 0.5) {
        return vec4(0.0);
    }
    float sky = texture2D(parameters, uv).r;
    return vec4(surface.rg, sky, surface.b);
#endif
}

vec3 readWaterScattering(sampler2D geometry, sampler2D scattering, vec2 uv) {
#ifdef WORLD_PACKED_WATER
    return readWaterPacket(geometry, uv).scattering;
#else
    return texture2D(scattering, uv).rgb;
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
        vec4 medium = texture2D(companionAtlas, vec2(0.5, 7.5) / companionAtlasSize());
#endif
        if (abs(medium.w - 1573.0) < 0.5 && medium.z > 0.5) {
            return medium.xy;
        }
    }
    float depthSum = 0.0;
    float skySum = 0.0;
    float count = 0.0;
    for (int x = 0; x < 3; x++) {
        for (int y = 0; y < 3; y++) {
            vec2 uv = vec2(0.15 + float(x) * 0.35, 0.60 + float(y) * 0.18);
            vec4 surface = readWaterSurface(surfaces, parameters, uv);
            if (surface.a > 0.001) {
                vec3 normal = mat3(gbufferModelViewInverse) * decodeWaterNormal(surface.xy);
                vec3 relative = (gbufferModelViewInverse
                    * vec4(waterSurfacePosition(uv, surface.a), 1.0)).xyz;
                if (relative.y > 0.02 && abs(normal.y) > 0.75) {
                    depthSum += relative.y;
                    skySum += surface.b;
                    count += 1.0;
                }
            }
        }
    }
    float skylight = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
    float fallback = (1.0 - skylight) * 15.0;
    float depth = clamp(count > 0.0 ? depthSum / count : fallback, 0.0, 64.0);
    return vec2(depth, count > 0.0 ? skySum / count : skylight);
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
