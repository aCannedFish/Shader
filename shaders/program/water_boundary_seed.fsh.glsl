/* 岸线与水底折角的半分辨率种子。C14的材质参数已在deferred1消费，
 * 此后复用其左下区域；只从原生水面覆盖和不透明深度检测边界。
 */
/* RENDERTARGETS: 14 */
#include "../settings.glsl"
#include "../lib/uniforms.glsl"
uniform sampler2D colortex5;
uniform sampler2D depthtex1;

vec2 boundaryUv(vec2 pixel) {
    vec2 size = vec2(viewWidth, viewHeight);
    return (clamp(pixel, vec2(0.0), size - 1.0) + 0.5) / size;
}

// 投影深度在平面内部线性变化；二阶差分检测台阶、轮廓和朝向突变。
bool boundaryCrease(float minus, float centre, float plus) {
    float first = centre - minus;
    float second = plus - centre;
    return abs(first - second) > max(0.0000003, min(abs(first), abs(second)) * 0.3);
}

bool waterBoundaryAt(vec2 pixel) {
    vec2 uv = boundaryUv(pixel);
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    float coverage = step(0.5, texture2D(colortex5, uv).a);
    float left = step(0.5, texture2D(colortex5, boundaryUv(pixel - vec2(1.0, 0.0))).a);
    float right = step(0.5, texture2D(colortex5, boundaryUv(pixel + vec2(1.0, 0.0))).a);
    float down = step(0.5, texture2D(colortex5, boundaryUv(pixel - vec2(0.0, 1.0))).a);
    float up = step(0.5, texture2D(colortex5, boundaryUv(pixel + vec2(0.0, 1.0))).a);
    if (left != coverage || right != coverage || down != coverage || up != coverage) return true;
    if (coverage < 0.5) return false;
    if (any(lessThan(pixel, vec2(1.0)))
        || any(greaterThanEqual(pixel, vec2(viewWidth, viewHeight) - 1.0))) return true;
    float depth = texture2D(depthtex1, uv).r;
    return boundaryCrease(texture2D(depthtex1, uv - vec2(texel.x, 0.0)).r,
            depth, texture2D(depthtex1, uv + vec2(texel.x, 0.0)).r)
        || boundaryCrease(texture2D(depthtex1, uv - vec2(0.0, texel.y)).r,
            depth, texture2D(depthtex1, uv + vec2(0.0, texel.y)).r);
}

void main() {
    gl_FragData[0] = vec4(-1.0, -1.0, 0.0, 0.0);
    vec2 size = vec2(viewWidth, viewHeight);
    if (isEyeInWater != 0 || WATER_REFRACTION_STRENGTH <= 0.0
        || any(greaterThanEqual(gl_FragCoord.xy, ceil(size * 0.5)))) return;
    vec2 base = floor(gl_FragCoord.xy) * 2.0;
    bool edge = false;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            edge = waterBoundaryAt(base + vec2(float(x), float(y))) || edge;
        }
    }
    if (edge) gl_FragData[0] = vec4(gl_FragCoord.xy, 0.0, 1.0);
}
