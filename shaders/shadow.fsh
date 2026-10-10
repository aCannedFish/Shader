#version 120

/* 日月阴影深度阶段。按贴图 alpha 拒绝镂空部分，避免树叶和植物被当作完整实心面。
 */

#include "/settings.glsl"
#include "/lib/uniforms.glsl"

uniform sampler2D texture;

varying vec2 vTexCoord;
varying vec4 vColor;

void main() {
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;

    // 半透明像素直接丢弃，不写深度，也就不会投射阴影。
    if (albedo.a < alphaTestRef) {
        discard;
    }

    // 没有颜色输出：阴影贴图只用到深度。
    // GPU 会自动把当前片元的 gl_FragCoord.z 写进深度附件。
}
