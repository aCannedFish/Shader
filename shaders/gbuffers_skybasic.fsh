#version 120

/* RENDERTARGETS: 0 */

/*
================================================================================
 gbuffers_skybasic.fsh —— 原版天空（渐变穹顶）片元着色器
================================================================================
 天空的处理哲学和其它几何体完全相反：

   * 不做光照 —— 天空本身【就是】光源，它不应该被自己照亮。
   * 不做雾   —— 雾是为了让远处物体融入天空；天空自己就是背景，
                 再叠一层雾只会让地平线变脏。
   * 保留顶点 alpha —— 日出日落的扇形光晕和地平线层需要混合。

 这里只写 colortex0（颜色），不写 colortex1 / colortex2。
 因为"天空的法线""天空的阴影系数"没有任何意义，
 写进去反而会让后处理读到错误数据（例如把天空当成一块朝向某个方向的墙，
 从而给它加上错误的屏幕空间效果）。
================================================================================
*/

#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color_space.glsl"
#include "/lib/fog.glsl"
#include "/lib/varyings.glsl"

// 天空、日落光晕和星星都使用本程序；只重算天空基础层。
uniform int renderStage;

#ifndef MC_RENDER_STAGE_SKY
#define MC_RENDER_STAGE_SKY 1
#endif
#ifndef MC_RENDER_STAGE_SUNSET
#define MC_RENDER_STAGE_SUNSET 2
#endif
#ifndef MC_RENDER_STAGE_VOID
#define MC_RENDER_STAGE_VOID 7
#endif

void main() {
    // 原版日落扇面是一块带硬边的独立几何层。
    // 本光影由下面的连续天空渐变表达日落，避免这块红色三角形盖住天空。
    if (renderStage == MC_RENDER_STAGE_SUNSET) {
        discard;
    }

    // 原版天空的顶点色与雾色同处显示空间。转为线性空间后，
    // 与地形、雾和泛光一起接受 final.fsh 的色调映射。
    vec3 color = toLinearSpace(vColor.rgb);

    if (renderStage == MC_RENDER_STAGE_SKY
        || renderStage == MC_RENDER_STAGE_VOID) {
        if (isEyeInWater == 1) {
            // 水下的远景应融入水下雾，避免透出一块陆地天空色。
            color = getFogColor();
        } else {
            // 用屏幕坐标反投影得到当前像素在世界空间中的视线方向。
            // 同一条曲线覆盖天空穹顶与地平线几何体，消除两者的硬接缝。
            vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
            vec4 viewRay = gbufferProjectionInverse
                         * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
            vec3 worldRay = safeNormalize(
                mat3(gbufferModelViewInverse) * viewRay.xyz,
                vec3(0.0, 1.0, 0.0)
            );
            float skyAmount = smoothstep(-0.10, 0.28, worldRay.y);
            color = mix(
                toLinearSpace(fogColor),
                toLinearSpace(skyColor),
                skyAmount
            );
        }
    }

    gl_FragData[0] = vec4(color, vColor.a);
}
