/* 保存下一帧使用的单纹素介质历史；从原生水面附件估计，不接收外部世界数据。 */
/* RENDERTARGETS: 13 */
#include "../lib/water.glsl"
uniform sampler2D colortex5;
uniform sampler2D colortex1;

void main() {
    vec2 medium = isEyeInWater == 1 ? estimateWaterMedium(colortex5, colortex1) : vec2(0.0);
    gl_FragData[0] = vec4(medium, float(frameCounter), isEyeInWater == 1 ? 4183.0 : 0.0);
}
