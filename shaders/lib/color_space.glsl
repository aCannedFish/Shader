/*
 * color_space.glsl —— 游戏颜色输入的显示空间转换。
 *
 * 贴图、顶点色、天空色和雾色由游戏按显示颜色提供。它们参与光照、
 * 雾和泛光之前，先转到线性空间；final.fsh 最后再编码回显示空间。
 * 这里使用与 lib/tonemap.glsl 相配的 gamma 2.2 近似。
 */
#ifndef LIB_COLOR_SPACE_GLSL
#define LIB_COLOR_SPACE_GLSL

vec3 toLinearSpace(vec3 color) {
    return pow(max(color, vec3(0.0)), vec3(2.2));
}

#endif
