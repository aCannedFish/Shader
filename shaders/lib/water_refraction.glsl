/* 空气到水的折射。由水面法线和折射率确定一条 Snell 光线，再求水底取样位置。
 * 水面覆盖和水底表面的边界提前收窄偏移，不在不连续的深度之间迭代跳转。
 */
#ifndef LIB_WATER_REFRACTION_GLSL
#define LIB_WATER_REFRACTION_GLSL
#include "water.glsl"
#include "space.glsl"
uniform sampler2D colortex14;

// 深度属于离散像素；法线、位置与颜色必须使用同一像素中心。
vec2 waterBedUv(vec2 uv) {
    vec2 size = vec2(viewWidth, viewHeight);
    return (clamp(floor(uv * size), vec2(0.0), size - 1.0) + 0.5) / size;
}

// 同一表面的单侧差分避免岸壁深度跳变把水底法线拉向屏外前景。
vec3 waterBedPoint(vec2 pixel, sampler2D opaqueDepth) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 uv = (clamp(pixel, vec2(0.0), size - 1.0) + 0.5) / size;
    float depth = texture2D(opaqueDepth, uv).r;
    return screenToView(uv, min(depth, 0.99999));
}

vec3 waterBedNormal(vec2 uv, vec3 centre, sampler2D opaqueDepth) {
    vec2 pixel = floor(uv * vec2(viewWidth, viewHeight));
    vec3 left = waterBedPoint(pixel - vec2(1.0, 0.0), opaqueDepth);
    vec3 right = waterBedPoint(pixel + vec2(1.0, 0.0), opaqueDepth);
    vec3 down = waterBedPoint(pixel - vec2(0.0, 1.0), opaqueDepth);
    vec3 up = waterBedPoint(pixel + vec2(0.0, 1.0), opaqueDepth);
    vec3 dx = abs(left.z - centre.z) < abs(right.z - centre.z) ? centre - left : right - centre;
    vec3 dy = abs(down.z - centre.z) < abs(up.z - centre.z) ? centre - down : up - centre;
    vec3 fallback = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    vec3 normal = safeNormalize(cross(dx, dy), fallback);
    normal *= dot(normal, -centre) >= 0.0 ? 1.0 : -1.0;
    return normalize(mat3(gbufferModelViewInverse) * normal);
}

// 先检查每个颜色纹素的几何，再插值；天空黑底、岸上前景与异面颜色不混入水底。
vec3 waterTransmissionColor(sampler2D scene, sampler2D opaqueDepth, vec2 uv,
                            vec3 bedWorld, vec3 bedNormal, float waterHeight) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    float tolerance = max(0.02, length(bedWorld - cameraPosition) * 0.002);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(base + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            vec2 sampleUv = (cell + 0.5) / size;
            float depth = texture2D(opaqueDepth, sampleUv).r;
            if (depth >= 0.999999) continue;
            vec3 world = viewToAbsoluteWorld(screenToView(sampleUv, depth));
            if (world.y >= waterHeight - 0.005 || abs(dot(world - bedWorld, bedNormal)) > tolerance) continue;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                * (y == 0 ? 1.0 - fraction.y : fraction.y);
            sum += texture2D(scene, sampleUv).rgb * weight;
            total += weight;
        }
    }
    vec2 centreUv = (clamp(floor(uv * size), vec2(0.0), size - 1.0) + 0.5) / size;
    return total > 0.00001 ? sum / total : texture2D(scene, centreUv).rgb;
}

// 只接受同一水位下的原生几何；屏外和岸上前景没有可用于水底的颜色。
bool waterRefractionDomain(vec2 uv, vec3 origin, sampler2D opaqueDepth,
                           sampler2D geometry, sampler2D parameters) {
    vec2 inset = 1.0 / vec2(viewWidth, viewHeight);
    if (any(lessThan(uv, inset)) || any(greaterThan(uv, 1.0 - inset))) return false;
    vec2 centre = waterBedUv(uv);
    vec4 water = readWaterSurface(geometry, parameters, centre);
    if (water.a <= 0.001) return false;
    vec3 interfacePoint = viewToAbsoluteWorld(waterSurfacePosition(centre, water.a));
    if (abs(interfacePoint.y - origin.y) > 0.25) return false;
    float depth = texture2D(opaqueDepth, centre).r;
    if (depth >= 0.999999) return false;
    vec3 point = viewToAbsoluteWorld(screenToView(centre, depth));
    return point.y < interfacePoint.y - 0.005;
}

// 对四个邻近传播结果取真实距离的最小值，不插值种子坐标，避免跨Voronoi边界跳动。
float waterBoundaryDistance(vec2 uv, sampler2D boundaryField) {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 point = uv * size * 0.5;
    vec2 base = floor(point - 0.5);
    float distance = min(min(uv.x, 1.0 - uv.x) * size.x,
        min(uv.y, 1.0 - uv.y) * size.y);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 pixel = clamp(base + vec2(float(x), float(y)), vec2(0.0), ceil(size * 0.5) - 1.0);
            vec4 seed = texture2D(boundaryField, (pixel + 0.5) / size);
            if (seed.a > 0.5) distance = min(distance, length(seed.xy - point) * 2.0);
        }
    }
    return max(distance - 3.0, 0.0);
}

// 在两倍偏移距离内平滑收窄，避免硬拒绝、边界拉丝和两幅水底叠加。
// 三像素余量覆盖半分辨率种子的位置误差及颜色滤波足迹。
float waterRefractionBoundary(vec2 uv, vec2 offset, sampler2D boundaryField) {
    float distance = waterBoundaryDistance(uv, boundaryField);
    return smoothstep(0.0, max(2.0 * length(offset * vec2(viewWidth, viewHeight)), 0.01), distance);
}

vec2 waterRefractionUv(vec2 uv, vec3 position, vec3 normal, vec3 bedWorld,
                       vec3 bedNormal, sampler2D opaqueDepth,
                       sampler2D geometry, sampler2D parameters) {
    if (WATER_REFRACTION_STRENGTH <= 0.0) return uv;
    vec3 origin = viewToAbsoluteWorld(position);
    if (!waterRefractionDomain(uv, origin, opaqueDepth, geometry, parameters)) return uv;
    vec3 incident = normalize(position);
    vec3 ray = refract(incident, normal, 1.0 / WATER_IOR);
    vec3 worldRay = mat3(gbufferModelViewInverse) * ray;
    float denominator = dot(bedNormal, worldRay);
    if (abs(denominator) < 0.04 || worldRay.y > -0.02) return uv;
    float distance = clamp(dot(bedNormal, bedWorld - origin) / denominator, 0.0, 48.0);
    vec4 clip = gbufferProjection * vec4(position + ray * distance, 1.0);
    if (clip.w <= 0.001) return uv;
    vec2 offset = (clip.xy / clip.w * 0.5 + 0.5 - uv) * WATER_REFRACTION_STRENGTH;
    if (length(offset * vec2(viewWidth, viewHeight)) < 0.01) return uv;
    float boundary = waterRefractionBoundary(uv, offset, colortex14);
    vec2 result = uv + offset * boundary;
    return waterRefractionDomain(result, origin, opaqueDepth, geometry, parameters)
        ? result : uv;
}
#endif
