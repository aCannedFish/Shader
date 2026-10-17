/* HDR 泛光：先逐样本提取亮部再降采样，随后执行可分离过滤。
 * 缓冲只使用左下有效视口，所有读取限制到有效纹素中心，避免采到旧天空/体积场。
 * 阈值和峰值限制先于平均，保留细小光源并抑制极亮像素的闪烁。
 */
#ifndef LIB_BLOOM_GLSL
#define LIB_BLOOM_GLSL
#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"

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
            sum += extractBloom(texture2D(source, sampleUv).rgb);
        }
    }
    return sum * 0.25;
#else
    return extractBloom(texture2D(source, uv).rgb);
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
    vec3 sum = texture2D(source, bloomUv(uv)).rgb * 0.161003374;
    sum += (texture2D(source, bloomUv(uv + stepUv * 1.440286351)).rgb
          + texture2D(source, bloomUv(uv - stepUv * 1.440286351)).rgb) * 0.265537291;
    sum += (texture2D(source, bloomUv(uv + stepUv * 3.363547460)).rgb
          + texture2D(source, bloomUv(uv - stepUv * 3.363547460)).rgb) * 0.123133699;
    sum += (texture2D(source, bloomUv(uv + stepUv * 5.293177779)).rgb
          + texture2D(source, bloomUv(uv - stepUv * 5.293177779)).rgb) * 0.030827323;
    return sum;
#endif
}
#endif
