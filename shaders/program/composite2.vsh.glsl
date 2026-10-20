/* 水下色调与雾色只依赖相机和入水深度，在全屏顶点上求值。
 * 各顶点读取相同的帧内元数据，避免所有片元重复计算相同的颜色和指数项。
 * UV 仍由片元位置重建，顶点只传递颜色常量。
 */
#include "../lib/water_volume.glsl"
uniform sampler2D colortex4;
varying vec3 vUnderwaterTint;
varying vec3 vUnderwaterScatter;

void main() {
    gl_Position = ftransform();
    vUnderwaterTint = vec3(1.0);
    vUnderwaterScatter = vec3(0.0);
    if (isEyeInWater == 1) {
        vec4 medium = texture2D(colortex4, vec2(0.5) / vec2(viewWidth, viewHeight));
        vUnderwaterTint = underwaterSceneTint(medium.a, medium.r);
        vUnderwaterScatter = underwaterScatterColor(medium.a, medium.r);
    }
}
