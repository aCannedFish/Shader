#version 120
/* deferred.fsh: build the sky-view LUT and adjacent world-space cloud shadow cache. */
/* RENDERTARGETS: 3 */
#include "lib/sky.glsl"
#include "lib/air_shadow.glsl"

void main() {
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0));
    if (gl_FragCoord.x >= size.x || gl_FragCoord.y >= size.y) {
        float shadow = 1.0;
        if (gl_FragCoord.x >= size.x && gl_FragCoord.x < size.x * 2.0
            && gl_FragCoord.y < size.y && isEyeInWater == 0) {
            vec2 uv = (gl_FragCoord.xy - vec2(size.x, 0.0)) / size;
            shadow = buildAirCloudShadow(uv, skySunDirection());
        }
        gl_FragData[0] = vec4(0.0, 0.0, 0.0, shadow);
        return;
    }
    vec2 coordinate = gl_FragCoord.xy / size;
    // 极点本身必须有一整行相同的辐射值，避免经线在中心收敛成亮点。
    coordinate.y = (gl_FragCoord.y - 0.5) / max(size.y - 1.0, 1.0);
    if (coordinate.y <= 0.0) {
        // 下极点没有方位角，用四个地平线方向的平均值作为统一边界。
        const float diagonal = 0.70710678;
        vec3 pole = integrateAtmosphere(vec3(diagonal, -diagonal, 0.0));
        pole += integrateAtmosphere(vec3(-diagonal, -diagonal, 0.0));
        pole += integrateAtmosphere(vec3(0.0, -diagonal, diagonal));
        pole += integrateAtmosphere(vec3(0.0, -diagonal, -diagonal));
        gl_FragData[0] = vec4(pole * 0.25, 1.0);
        return;
    }
    gl_FragData[0] = vec4(integrateAtmosphere(skyLookupDirection(coordinate)), 1.0);
}
