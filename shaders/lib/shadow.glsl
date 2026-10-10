/* 日月阴影采样。把表面投影到畸变阴影空间，按入射角修正偏移，执行 PCF 和距离淡出。
 * 片元阶段使用 shadowtex0，返回光源可见度。
 */
#ifndef LIB_SHADOW_GLSL
#define LIB_SHADOW_GLSL

#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"
#include "space.glsl"
#include "lighting.glsl"   // 需要 getLightDirView() 来计算入射角相关的偏移

// 阴影贴图。名称必须是加载器识别的 shadowtex0。
// 任意名称如 shadowMap 虽能通过 GLSL 编译，却不会绑定到阴影深度图。
// 这里用普通 2D 采样 + 手动比较（settings.glsl 中 shadowHardwareFiltering = false）。
uniform sampler2D shadowtex0;


/* ---------------------------------------------------------------------------
 * 单点深度比较
 *   返回 1 表示该点受光，0 表示被遮挡。
 * ------------------------------------------------------------------------ */
float sampleShadowMap(vec2 uv, float depth, float bias) {
    // texture2D(...).r 取出阴影贴图里存的深度值，范围 [0,1]
    float shadowDepth = texture2D(shadowtex0, uv).r;

    // step(edge, x)：x >= edge 时返回 1，否则返回 0。
    // 这里 edge = 当前深度 - 偏移量。
    // 减去偏移是为了让"表面恰好等于自身深度"的情况判为受光，
    // 否则表面会和自己比较失败，产生条纹状的自阴影（shadow acne）。
    return step(depth - bias, shadowDepth);
}


/* ---------------------------------------------------------------------------
 * PCF 过滤
 *   在 3x3（或 5x5）的邻域里多次采样并求平均，得到一个连续的阴影系数。
 *   这样阴影边缘会有柔和的过渡，而不是硬邦邦的锯齿。
 * ------------------------------------------------------------------------ */
float sampleShadowPCF(vec2 uv, float depth, float bias) {
    // 一个纹素在 UV 空间的宽度。shadowMapResolution 是 int，必须显式转 float。
    float texelSize = 1.0 / float(shadowMapResolution);

    float shadow = 0.0;
    float count  = 0.0;

    // 循环上下界都是编译期常量（来自 #define），GLSL 120 要求如此。
    // SHADOW_SOFTNESS = 1 时展开成 3x3 共 9 次采样。
    for (int x = -SHADOW_SOFTNESS; x <= SHADOW_SOFTNESS; x++) {
        for (int y = -SHADOW_SOFTNESS; y <= SHADOW_SOFTNESS; y++) {
            vec2 offset = vec2(float(x), float(y)) * texelSize;
            shadow += sampleShadowMap(uv + offset, depth, bias);
            count  += 1.0;
        }
    }

    return shadow / count;
}


/* ---------------------------------------------------------------------------
 * 对外的总入口：给一个顶点，算出它的阴影系数。
 *
 * 参数：
 *   shadowClipPos  顶点着色器里经过畸变的裁剪空间坐标（插值而来）
 *   normalView     视图空间法线，用来做入射角相关的偏移，以及判断是否背光
 *   viewDistance   该点到摄像机的距离，用来在 shadowDistance 附近淡出阴影
 *
 * 返回：1 = 完全受光，0 = 完全被遮挡。中间值是软阴影的过渡。
 * ------------------------------------------------------------------------ */
float getShadowFactor(vec4 shadowClipPos, vec3 normalView, float viewDistance) {
#if ENABLE_SHADOWS == 0
    // 关闭阴影时直接返回"全亮"，编译器会顺手把上面的采样代码全部优化掉。
    return 1.0;
#else
    // --- 1. 转换到阴影贴图的 UV 空间 ---
    // w <= 0 表示这个点在光源背后，不应该有阴影。
    if (shadowClipPos.w <= 0.0) return 1.0;

    vec3 shadowUv = shadowClipToUv(shadowClipPos);

    // --- 2. 超出阴影贴图范围的直接判为受光 ---
    // 阴影贴图只覆盖 shadowDistance 范围，范围外没有数据，硬判成阴影会出现
    // 一圈突兀的黑边。所以范围外返回全亮，并用下面的距离淡出平滑过渡。
    if (any(lessThan(shadowUv.xy, vec2(0.0))) || any(greaterThan(shadowUv.xy, vec2(1.0)))) {
        return 1.0;
    }

    // --- 3. 距离淡出 ---
    // 在 shadowDistance 的 75% 处开始淡出，到 95% 时完全消失。
    // 这样可以掩盖阴影贴图边缘精度不足导致的各种瑕疵。
    float fade = 1.0 - smoothstep(shadowDistance * 0.75, shadowDistance * 0.95, viewDistance);

    // --- 4. 入射角相关的深度偏移 ---
    // 光线越斜（N·L 越小），同样的几何误差在深度上的投影越大，
    // 需要更大的偏移量才能压住阴影痤疮。所以按 N·L 在两档之间插值。
    vec3 lightDirView = getLightDirView();
    float NdotL = clamp(dot(normalView, lightDirView), 0.0, 1.0);
    float bias = mix(SHADOW_BIAS * 8.0, SHADOW_BIAS, NdotL);

    // --- 5. 采样 ---
    float shadow = sampleShadowPCF(shadowUv.xy, shadowUv.z, bias);

    // --- 6. 应用距离淡出 ---
    // 近处（fade = 1）完整使用采样结果，远处（fade = 0）逐渐变成全亮，
    // 于是阴影贴图边缘处的瑕疵就被藏进了过渡带里。
    return mix(1.0, shadow, fade);
#endif
}

#endif  // LIB_SHADOW_GLSL
