#version 120

/* RENDERTARGETS: 0 */

/*
================================================================================
 gbuffers_skytextured.fsh —— 带贴图的天空
================================================================================
 采样贴图后直接输出，同样不做光照、不做雾。
 末地的紫色星空、OptiFine 自定义天空（如果启用）都会走这个程序。
================================================================================
*/

#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color_space.glsl"
#include "/lib/varyings.glsl"

// 天空贴图。和方块图集用的是同一个 uniform 名，但这里绑定的是天空纹理。
uniform sampler2D texture;

void main() {
    vec4 color = texture2D(texture, vTexCoord) * vColor;
    color.rgb = toLinearSpace(color.rgb);

    // 只写颜色。天空没有有意义的法线和光照数据，不写 G-Buffer。
    // 原版日月贴图为不透明黑底，用着色器配置中的加法混合让黑底消失。
    // alpha 保留，以兼容有透明通道的资源包。
    gl_FragData[0] = color;
}
