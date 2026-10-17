/* 日光体积阴影缓存。固定高度层积分云消光，世界坐标网格随相机平移时按格移动。
 * 缓存位于天空 LUT 右侧的 alpha 区域，沿光线投影后可查询任意近地面体积点。
 */
#ifndef LIB_AIR_SHADOW_GLSL
#define LIB_AIR_SHADOW_GLSL
#include "cloud_density.glsl"
#include "space.glsl"

const float AIR_SHADOW_EXTENT = 256.0;

vec2 airShadowOrigin() {
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0));
    vec2 cell = vec2(2.0 * AIR_SHADOW_EXTENT) / size;
    return floor(cameraPosition.xz / cell) * cell;
}

// 以固定云层高度采样，避免几何终点或像素深度重排采样位置。
float buildAirCloudShadow(vec2 coordinate, vec3 sun) {
    if (sun.y <= 0.02 || CLOUD_OPACITY <= 0.0 || CLOUD_SHADOW_STRENGTH <= 0.0) {
        return 1.0;
    }
    vec2 altitude = cloudAltitudeBounds();
    float bottom = max(altitude.x, cameraPosition.y);
    float distance = max(altitude.y - bottom, 0.0) / max(sun.y, 0.02);
    vec3 origin = vec3(airShadowOrigin().x + (coordinate.x * 2.0 - 1.0) * AIR_SHADOW_EXTENT,
                       cameraPosition.y,
                       airShadowOrigin().y + (coordinate.y * 2.0 - 1.0) * AIR_SHADOW_EXTENT);
    float start = max((bottom - origin.y) / max(sun.y, 0.02), 0.0);
    float opticalDepth = 0.0;
    for (int index = 0; index < 64; index++) {
        float along = start + (float(index) + 0.5) * distance / 64.0;
        opticalDepth += cloudDensity(origin + sun * along, false) * distance / 64.0;
    }
    float transmission = exp(-opticalDepth * 0.04 * CLOUD_OPACITY);
    return mix(1.0, transmission, CLOUD_SHADOW_STRENGTH);
}

// 缓存存的是标量透射率，可由附件的线性过滤直接插值；深度比较仍在各自
// 的阴影函数中逐纹素完成。有效纹素中心钳制防止读入相邻天空/云环境区域。
float sampleAirCloudShadow(sampler2D field, vec3 world, vec3 sun) {
    vec2 projected = world.xz + sun.xz * (cameraPosition.y - world.y) / max(sun.y, 0.02);
    vec2 coordinate = (projected - airShadowOrigin()) / (2.0 * AIR_SHADOW_EXTENT) + 0.5;
    float edge = min(min(coordinate.x, coordinate.y), min(1.0 - coordinate.x, 1.0 - coordinate.y));
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0));
    vec2 pixel = clamp(coordinate, 0.5 / size, 1.0 - 0.5 / size) * size;
    vec2 uv = (vec2(size.x, 0.0) + pixel) / vec2(viewWidth, viewHeight);
    float shadow = texture2D(field, uv).a;
    return mix(1.0, shadow, smoothstep(0.0, 0.08, edge) * smoothstep(0.03, 0.12, sun.y));
}
#endif
