/* 水下色调与雾色只依赖相机和入水深度，在全屏顶点上求值。
 * 各顶点读取相同的帧内元数据，避免所有片元重复计算相同的颜色和指数项。
 * UV 仍由片元位置重建，顶点只传递颜色常量。
 */
#include "../lib/water_volume.glsl"
uniform sampler2D colortex4;
#ifdef WORLD_BASE_OPTICS
#include "../lib/water.glsl"
uniform sampler2D colortex5;
uniform sampler2D colortex1;
varying float vUnderwaterDepth;
#endif
varying vec3 vUnderwaterTint;
varying vec3 vUnderwaterScatter;

void main() {
    gl_Position = ftransform();
    vUnderwaterTint = vec3(1.0);
    vUnderwaterScatter = vec3(0.0);
#ifdef WORLD_BASE_OPTICS
    vUnderwaterDepth = 0.0;
#endif
    if (isEyeInWater == 1) {
#ifdef WORLD_BASE_OPTICS
        vec2 estimate = estimateWaterMedium(colortex5, colortex1);
        vec4 medium = vec4(estimate.y, 0.0, 0.0, estimate.x);
        vUnderwaterDepth = medium.a;
#else
        vec4 medium = texture2D(colortex4, vec2(0.5) / vec2(viewWidth, viewHeight));
#endif
        vUnderwaterTint = underwaterSceneTint(medium.a, medium.r);
        vUnderwaterScatter = underwaterScatterColor(medium.a, medium.r);
    }
}
