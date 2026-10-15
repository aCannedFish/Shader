/* HDR 亮部软阈值与可分离泛光。两次一维过滤复用现有附件，控制采样间距，
 * 归一化核保留亮部能量；极亮圆盘的贡献设上限，避免形成大片白雾。
 */
#ifndef LIB_BLOOM_GLSL
#define LIB_BLOOM_GLSL
#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"

vec3 extractBloom(vec3 color) {
    float brightness = luma(color);
    float knee = max(BLOOM_THRESHOLD * 0.5, 0.001);
    float soft = clamp(brightness - BLOOM_THRESHOLD + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee);
    float energy = min(max(soft, brightness - BLOOM_THRESHOLD), 6.0);
    return color * max(energy, 0.0) / max(brightness, EPSILON);
}

// 水平阶段先提取亮部；垂直阶段读取水平结果，合成完整的二维平滑核。
vec3 filterBloom(sampler2D source, vec2 uv, vec2 axis, bool extract) {
#if ENABLE_BLOOM == 0
    return vec3(0.0);
#else
    vec2 size = vec2(viewWidth, viewHeight);
    float spacing = min(1.5 * BLOOM_RADIUS * min(viewWidth, viewHeight) / 1080.0, 2.0);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int index = -6; index <= 6; index++) {
        vec2 coordinate = clamp(uv + axis * float(index) * spacing / size,
                                0.5 / size, 1.0 - 0.5 / size);
        vec3 color = texture2D(source, coordinate).rgb;
        if (extract) {
            color = extractBloom(color);
        }
        float weight = exp(-float(index * index) * 0.08);
        sum += color * weight;
        total += weight;
    }
    return sum / total;
#endif
}
#endif
