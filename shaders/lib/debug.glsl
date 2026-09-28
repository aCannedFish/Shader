/*
================================================================================
 lib/debug.glsl —— 调试可视化
================================================================================
 光影开发里 90% 的时间花在"为什么这里不对"上。把中间数据直接画到屏幕上，
 比反复改数值猜原因快得多。这个文件提供一组调试视图。

 在 settings.glsl 里把 DEBUG_VIEW 改成对应数字（或游戏内设置界面切换），
 然后在游戏里按 F3 观察就行。

 常用排查套路：
   * 阴影位置全错        -> 看 DEBUG_VIEW 3，确认阴影系数是否跟物体一致
   * 法线反了 / 发黑     -> 看 DEBUG_VIEW 1，正常应该是"朝上是绿、朝右是红"
   * 光照贴图没更新      -> 看 DEBUG_VIEW 2，火把附近应该是红/黄色块
   * 后处理把画面搞灰了  -> 看 DEBUG_VIEW 5，确认泛光缓冲是否正常
================================================================================
*/
#ifndef LIB_DEBUG_GLSL
#define LIB_DEBUG_GLSL

#include "/settings.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/common.glsl"
#include "/lib/space.glsl"

/* 本文件【不声明】任何采样器，因为不同程序要读的纹理不一样。
 * 调用方必须先自行声明下面这些（用不到的可以不声明，
 * 但那样就不能启用对应的调试视图）：
 *
 *   uniform sampler2D depthtex0;   深度缓冲，[0,1] 非线性深度
 *   uniform sampler2D colortex1;   r,g = 法线 xy 编码，b = 天空光，a = 材质
 *   uniform sampler2D colortex2;   r = 方块光，g = 天空光，b = 阴影系数
 *   uniform sampler2D colortex4;   模糊后的泛光
 */


/* ---------------------------------------------------------------------------
 * 主分发函数
 *   color        已经算完的正常画面颜色
 *   screenCoord  当前像素的屏幕 UV [0,1]
 *   返回：调试开启时返回调试颜色，关闭时原样返回 color
 * ------------------------------------------------------------------------ */
vec3 applyDebugView(vec3 color, vec2 screenCoord) {
#if DEBUG_VIEW == 0
    return color;
#else
    // 采样三张 G-Buffer，按需取用。
    vec4 geomBuffer = texture2D(colortex1, screenCoord);
    vec4 lightBuffer = texture2D(colortex2, screenCoord);

    #if DEBUG_VIEW == 1
        // 视图空间法线，编码在 RG 两个通道里（见 lib/common.glsl 的 encodeNormal）
        vec3 normal = decodeNormal(geomBuffer.rg);
        // 映射到 [0,1] 方便观察：朝右 = 红，朝上 = 绿，朝摄像机 = 蓝
        return normal * 0.5 + 0.5;

    #elif DEBUG_VIEW == 2
        // 光照贴图坐标：r = 方块光，g = 天空光
        return vec3(lightBuffer.r, lightBuffer.g, 0.0);

    #elif DEBUG_VIEW == 3
        // 阴影系数：白 = 受光，黑 = 被遮挡
        return vec3(lightBuffer.b);

    #elif DEBUG_VIEW == 4
        // 原始深度缓冲，直接可视化（近处黑、远处白）
        // 想看得更清楚可以换成 linearizeDepth(...) / far
        float depth = texture2D(depthtex0, screenCoord).r;
        return vec3(depth);

    #elif DEBUG_VIEW == 5
        // 泛光缓冲
        return texture2D(colortex4, screenCoord).rgb;

    #elif DEBUG_VIEW == 6
        // 由深度还原视图空间坐标，可视化 xyz。
        // 这是在为 SSAO / 屏幕空间反射做准备，能直观确认坐标还原是否正确。
        float depth = texture2D(depthtex0, screenCoord).r;
        vec3 viewPos = screenToView(screenCoord, depth);
        return abs(viewPos) / far;

    #else
        return color;
    #endif
#endif
}

#endif  // LIB_DEBUG_GLSL
