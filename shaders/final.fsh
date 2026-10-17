#version 120

/* 最终输出。轻度径向色差、泛光与太阳镜头光晕先在线性空间合成，
 * 再应用夜间曝光、色调映射和颜色调整，最后编码到显示空间。
 * 调试视图可替换最终颜色输出。
 */

#include "settings.glsl"
#include "lib/uniforms.glsl"
#include "lib/common.glsl"
#include "lib/space.glsl"
#include "lib/tonemap.glsl"
#include "lib/noise.glsl"
#include "lib/bloom.glsl"

// 场景颜色（所有 gbuffers 程序的输出，包含半透明物体）
uniform sampler2D colortex0;

// 模糊后的泛光
uniform sampler2D colortex3;

// 下面这几个是 lib/debug.glsl 的调试视图要用的。
// 该文件自己不声明采样器（因为它被不同程序共用，能读到的纹理不一样），
// 所以在这里统一声明。用不到的调试视图会被编译器优化掉。
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D depthtex0;

#include "lib/debug.glsl"
#include "lib/lens_optics.glsl"

varying vec2 vScreenUv;

void main() {
    // final 的视口是输出窗口；viewWidth/Height 仍表示内部纹理尺寸。
    vec2 screenCoord = vScreenUv;

    /* -----------------------------------------------------------------------
     * 第一步：取出场景颜色
     * -------------------------------------------------------------------- */
    vec3 color = sampleChromaticScene(colortex0, screenCoord);

    /* -----------------------------------------------------------------------
     * 第二步：叠加泛光
     * 泛光是"额外的光"，所以是加法而不是混合。
     * BLOOM_STRENGTH 控制它有多强；太大会让画面糊成一团。
     * -------------------------------------------------------------------- */
#if ENABLE_BLOOM == 1
    vec3 bloom = texture2D(colortex3, bloomUv(screenCoord)).rgb;
    color += bloom * BLOOM_STRENGTH;
#endif

    float solarVisibility = texture2D(colortex3, vec2(0.5) / vec2(viewWidth, viewHeight)).a;
    color += lensFlare(screenCoord, solarVisibility);

    /* -----------------------------------------------------------------------
     * 第三步：色调映射（含曝光、饱和度、对比度）
     * 把可能远超 1.0 的 HDR 颜色压回 [0,1]。
     * 这是"为什么高光不会死白"的原因，详见 lib/tonemap.glsl。
     * -------------------------------------------------------------------- */
    // 夜间只抬升暗部；亮光附近逐渐回到基础曝光，避免整片照明被一起放大。
    vec3 sunWorld = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    float night = 1.0 - smoothstep(-0.16, 0.12, sunWorld.y);
    // 有理衰减使最终亮度保持单调，较大的用户曝光值也不会形成反向光圈。
    float shadowLift = 0.04 / (0.04 + max(luma(color), 0.0));
    color *= mix(1.0, NIGHT_EXPOSURE, night * shadowLift);
    color = applyTonemap(color);

    /* -----------------------------------------------------------------------
     * 第四步：暗角（vignette）
     * 模拟镜头边缘进光量下降，把注意力集中到画面中心。
     * 这里在"以中心为原点"的坐标上算距离平方，再用它压暗。
     * 乘上 aspectRatio 是为了让暗角在宽屏上保持圆形而不是椭圆。
     *
     * 注意这里没有用 #if 包起来：GLSL 的预处理器只支持整数常量表达式，
     * 写 `#if VIGNETTE > 0.0` 是编译错误。好在 VIGNETTE = 0 时
     * 下面这两行的结果就是原值，等于关闭，代价可以忽略。
     * -------------------------------------------------------------------- */
    vec2 centered = (screenCoord - 0.5) * vec2(aspectRatio, 1.0);
    color *= 1.0 - VIGNETTE * dot(centered, centered) * 2.0;

    /* -----------------------------------------------------------------------
     * 第五步：线性空间 -> 显示空间
     * 把线性光强转换成显示器期望的 sRGB 信号。
     * -------------------------------------------------------------------- */
    color = toDisplaySpace(color);

    /* -----------------------------------------------------------------------
     * 第六步：抖动
     * 打散 8 位色深带来的色带。
     * 必须放在 gamma 编码【之后】，因为色带是在最终的显示值上产生的。
     * -------------------------------------------------------------------- */
    color = applyDither(color, screenCoord);

    /* -----------------------------------------------------------------------
     * 第七步：调试视图
     * 必须在最后一步，因为它要绕过上面所有处理直接显示原始数据。
     * settings.glsl 里把 DEBUG_VIEW 设成非 0 即可启用。
     * -------------------------------------------------------------------- */
    color = applyDebugView(color, screenCoord);

    /* -----------------------------------------------------------------------
     * 输出到屏幕
     * -------------------------------------------------------------------- */
    gl_FragData[0] = vec4(color, 1.0);
}
