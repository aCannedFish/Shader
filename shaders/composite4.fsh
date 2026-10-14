#version 120

/* 泛光过滤。读取 composite3 提取的 HDR 亮部，使用归一化 5×5 高斯核写入 colortex4。
 */

/* RENDERTARGETS: 4 */

#include "settings.glsl"
#include "lib/uniforms.glsl"
#include "lib/common.glsl"
#include "lib/space.glsl"

// 上一步提取出来的亮部
uniform sampler2D colortex3;


void main() {
    vec2 screenCoord = gl_FragCoord.xy / vec2(viewWidth, viewHeight);

    // 一个像素在 UV 空间的尺寸
    vec2 texelSize = getTexelSize();

    // 模糊半径：以像素为单位。BLOOM_RADIUS 是设置里的倍率。
    // 半径越大光晕越"散"，但采样点之间的空隙也越大，
    // 超过约 8 像素就会开始出现块状伪影。
    // 更大的半径需要配合降采样以控制伪影。
    float radius = 2.0 * BLOOM_RADIUS;

    // 高斯函数的标准差 σ。经验上取核半径的一半左右，曲线最自然。
    // 这里的"距离"是按网格步数算的（中心点为 0，向外到 2），
    // 所以 σ 也用步数而不是像素作单位。
    float sigma = max(BLOOM_RADIUS, 0.5);
    float twoSigmaSq = 2.0 * sigma * sigma;

    vec3 sum = vec3(0.0);
    float weightSum = 0.0;

    // 5x5 高斯核。循环上下界是常量，GLSL 120 才会允许这样写。
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            // 采样位置：先在 UV 空间偏移一个像素，再乘上模糊半径
            vec2 offset = vec2(float(x), float(y)) * texelSize * radius;

            // 二维高斯权重：exp(-r² / (2σ²))
            // 因为高斯是各向同性的，权重只取决于到中心的距离平方。
            float distSq = float(x * x + y * y);
            float weight = exp(-distSq / twoSigmaSq);

            sum += texture2D(colortex3, screenCoord + offset).rgb * weight;
            weightSum += weight;
        }
    }

    // 除以权重和做归一化，保证模糊前后整体亮度不变
    // （不归一化的话画面会越模糊越亮）。
    gl_FragData[0] = vec4(sum / weightSum, 1.0);
}
