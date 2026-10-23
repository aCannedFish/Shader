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
