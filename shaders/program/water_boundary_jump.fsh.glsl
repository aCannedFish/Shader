/* 在C14的半分辨率区域传播最近边界种子。八次有界jump flood覆盖512像素，
 * 各阶段独立读写翻转银行，不增加持久纹理，也不改变水底几何或颜色。
 */
/* RENDERTARGETS: 14 */
#include "../settings.glsl"
#include "../lib/uniforms.glsl"
uniform sampler2D colortex14;

void main() {
    gl_FragData[0] = vec4(-1.0, -1.0, 0.0, 0.0);
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 fieldSize = ceil(size * 0.5);
    if (isEyeInWater != 0 || WATER_REFRACTION_STRENGTH <= 0.0
        || any(greaterThanEqual(gl_FragCoord.xy, fieldSize))) return;
    float nearest = 1.0e20;
    vec4 result = vec4(-1.0, -1.0, 0.0, 0.0);
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 pixel = gl_FragCoord.xy + vec2(float(x), float(y)) * float(WATER_BOUNDARY_JUMP);
            if (any(lessThan(pixel, vec2(0.0))) || any(greaterThanEqual(pixel, fieldSize))) continue;
            vec4 candidate = texture2D(colortex14, pixel / size);
            if (candidate.a < 0.5) continue;
            vec2 delta = candidate.xy - gl_FragCoord.xy;
            float distanceSquared = dot(delta, delta);
            if (distanceSquared < nearest) {
                nearest = distanceSquared;
                result = candidate;
            }
        }
    }
    gl_FragData[0] = result;
}
