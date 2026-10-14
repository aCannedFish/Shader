/*
================================================================================
 lib/varyings.glsl —— 顶点着色器 -> 片元着色器 的数据传递
================================================================================
 varying 是顶点着色器的输出、片元着色器的输入，GPU 会在三角形内部做插值。

 顶点和片元两侧的 varying 声明【必须完全一致】（名称、类型、顺序无所谓但
 名称必须相同），否则链接会失败或数据错乱。为了避免两边写不一样，
 本项目把 varying 集中在这里，两侧都 #include 这一份。

 插值的含义：如果一个三角形三个顶点分别是红、绿、蓝，中间像素拿到的
 是三者按距离加权的结果 —— 这就是为什么渐变能自动生效。
================================================================================
*/
#ifndef LIB_VARYINGS_GLSL
#define LIB_VARYINGS_GLSL

// 贴图坐标，来自 gl_TextureMatrix[0] * gl_MultiTexCoord0。
varying vec2 vTexCoord;

// 顶点颜色，来自 gl_Color。包含了方块的生物群系染色（草/树叶的绿色）
// 以及一些特殊渲染的颜色信息。
varying vec4 vColor;

// 光照贴图坐标，来自 gl_TextureMatrix[1] * gl_MultiTexCoord1。
// x = 方块光等级 / 15，y = 天空光等级 / 15，范围都是 [0,1]。
varying vec2 vLightmapCoord;

// 视图空间法线，已归一化。光照计算靠它。
varying vec3 vNormalView;

// 视图空间位置。摄像机在原点，看向 -Z。
// 用途：算到摄像机的距离（雾）、算视线方向（高光）、做屏幕空间效果。
varying vec3 vViewPos;

// 未畸变的阴影裁剪坐标。先插值到片元，再除以 w 并施加径向畸变，
// 避免非线性畸变在顶点之间插值时移动接收点。
varying vec4 vShadowClipPos;

// 方块/实体 ID。x = 方块或实体的数字 ID，y = 渲染类型。
// 有了它就能针对特定方块写特效，例如：
//   if (vEntityId.x == 8.0 || vEntityId.x == 9.0) { /* 流水 */ }
varying vec2 vEntityId;

#endif  // LIB_VARYINGS_GLSL
