/*
 * 植被顶点风摆。地形和阴影共用世界坐标、时间、分类与位移函数。
 * 叶片采用连续空间场以保持相邻方块接缝；草/花/作物以根部为固定支点。
 * 两格植物的上下部分使用同一根部、相位和高度曲线。
 */
#ifndef LIB_FOLIAGE_WIND_GLSL
#define LIB_FOLIAGE_WIND_GLSL

#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"

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
