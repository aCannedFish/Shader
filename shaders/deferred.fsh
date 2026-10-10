#version 120
/* deferred.fsh: build a small dynamic sky-view lookup in the lower-left region. */
/* RENDERTARGETS: 3 */
#include "/lib/sky.glsl"

void main() {
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0));
    vec2 coordinate = gl_FragCoord.xy / size;
    gl_FragData[0] = vec4(integrateAtmosphere(skyLookupDirection(coordinate)), 1.0);
}
