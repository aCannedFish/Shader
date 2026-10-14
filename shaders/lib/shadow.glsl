/* 日月阴影入口。普通材质使用包含透明几何的深度图。 */
#ifndef LIB_SHADOW_GLSL
#define LIB_SHADOW_GLSL
#include "shadow_filter.glsl"

uniform sampler2D shadowtex0;

float getShadowFactor(vec4 shadowClipPos, vec3 normalView, float viewDistance) {
    return sampleSoftDirectionalShadow(shadowtex0, shadowClipPos, normalView, viewDistance);
}

#endif
