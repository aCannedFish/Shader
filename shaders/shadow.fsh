#version 120

/* 日月阴影深度阶段。按贴图 alpha 拒绝镂空部分，避免树叶和植物被当作完整实心面。
 */

#include "settings.glsl"
#include "lib/uniforms.glsl"
#include "lib/space.glsl"

uniform sampler2D texture;

varying vec2 vTexCoord;
varying vec4 vColor;
varying vec3 vShadowPosition;

void main() {
    // 在 alpha 丢弃前求导，保证叶片边缘仍有完整的导数四像素组。
    vec3 plane = cross(dFdx(vShadowPosition), dFdy(vShadowPosition));
    float planeScale = max(max(abs(plane.x), abs(plane.y)), abs(plane.z));
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;

    // 半透明像素直接丢弃，不写深度，也就不会投射阴影。
    if (albedo.a < alphaTestRef) {
        discard;
    }

    // 非线性畸变后的线性深度插值不再落在原始平面上，会产生圆斑状自阴影。
    // 反解当前纹素位置，再由原始平面求深度；掠射退化三角形保留光栅深度。
    gl_FragDepth = gl_FragCoord.z;
    if (abs(plane.z) > planeScale * 0.00001) {
        vec2 distorted = gl_FragCoord.xy / shadowTextureResolution() * 2.0 - 1.0;
        vec2 original = undistortShadow(distorted);
        float depth = vShadowPosition.z
                    - dot(plane.xy, original - vShadowPosition.xy) / plane.z;
        gl_FragDepth = clamp(depth * 0.5 + 0.5, 0.0, 1.0);
    }
}
