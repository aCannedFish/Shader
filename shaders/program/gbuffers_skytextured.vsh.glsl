
/*
================================================================================
 gbuffers_skytextured.vsh —— 带贴图的天空（末地天空、自定义天空）
================================================================================
 与 skybasic 的唯一区别：这类天空用贴图而不是纯色渐变，
 所以需要把变换后的 gl_MultiTexCoord0 传给片元着色器。
================================================================================
*/

#include "../settings.glsl"
#include "../lib/uniforms.glsl"
#include "../lib/common.glsl"
#include "../lib/varyings.glsl"


void main() {
    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;

    vTexCoord      = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vColor         = gl_Color;
    vNormalView    = vec3(0.0, 0.0, 1.0);
    vViewPos       = vec3(0.0, 0.0, -1.0);
    vShadowClipPos = vec4(0.0);
    vLightmapCoord = vec2(1.0);
    vEntityId      = vec2(0.0);
}
