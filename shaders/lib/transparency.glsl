/* 透明方块颜色独立于水面保存。RGB 是预乘辐射，alpha 是累计覆盖率；
 * 水面阶段可把这层放在水体之前或之后，水下视角也能保留玻璃。
 */
#ifndef LIB_TRANSPARENCY_GLSL
#define LIB_TRANSPARENCY_GLSL

vec3 applyTransparentLayer(vec3 background, vec4 layer) {
    return layer.rgb + background * (1.0 - clamp(layer.a, 0.0, 1.0));
}

bool transparentLayerInFront(float sceneDepth, float waterDepth, float coverage) {
    return coverage > 0.001 && sceneDepth < waterDepth - max(0.03, waterDepth * 0.001);
}

#endif
