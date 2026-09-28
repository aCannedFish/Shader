#version 120

/*
================================================================================
 composite.fsh —— 泛光第一步：亮部提取
================================================================================
 泛光（bloom）模拟的是真实摄像机和眼睛的"光晕"：
 特别亮的东西（太阳、火把、附魔光效）会把光"溢"到周围的像素上。

 整个算法分三步：
   1. 【本文件】把画面里亮度超过阈值的部分单独提取出来，写到 colortex3；
   2. composite1.fsh 对 colortex3 做大范围模糊，写到 colortex4；
   3. final.fsh 把模糊结果叠加回原图。

 为什么必须拆成两个程序？
   因为"同一次绘制里不能既读又写同一张纹理"。
   提取和模糊都是对整张图的读写，必须各自占用一张输出纹理。

 RENDERTARGETS 指令：告诉驱动这次绘制写哪张纹理。
   不写的话默认写 colortex0 —— 那会把刚画好的场景直接覆盖掉。
================================================================================
*/

/* RENDERTARGETS: 3 */

#include "/settings.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/common.glsl"

// 上一步（gbuffers 等）画好的场景颜色
uniform sampler2D colortex0;


void main() {
    // 用 gl_FragCoord 直接算出当前像素的 UV，避免依赖插值的纹理坐标。
    vec2 screenCoord = gl_FragCoord.xy / vec2(viewWidth, viewHeight);

    vec3 color = texture2D(colortex0, screenCoord).rgb;

#if ENABLE_BLOOM == 0
    // 关闭泛光时也要写一个确定的值（这里是 0），
    // 否则 colortex3 里会留着别的程序的残留数据。
    gl_FragData[0] = vec4(0.0, 0.0, 0.0, 1.0);
#else
    // --- 软阈值 ---
    // 亮度（luma）超过阈值多少，就保留多少比例。
    // 这样阈值附近的像素是平滑过渡进来的，
    // 不会出现"亮度刚好卡在阈值上的方块突然开始发光"的突变。
    float brightness = luma(color);
    float contribution = max(brightness - BLOOM_THRESHOLD, 0.0) / max(brightness, EPSILON);

    gl_FragData[0] = vec4(color * contribution, 1.0);
#endif
}
