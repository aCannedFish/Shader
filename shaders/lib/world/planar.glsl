/* A reflected camera is rasterized from the actual submitted block triangles.
 * The capture plane and next-frame selection are separate: changing water level
 * cannot reinterpret a depth image rendered using a different mirror plane.
 */
#ifndef SIMPLE_WORLD_PLANAR_GLSL
#define SIMPLE_WORLD_PLANAR_GLSL
#include "/lib/world/lookup.glsl"
#include "/lib/world/history.glsl"

vec4 worldPlanarWord(sampler2D data, int word, bool next) {
    return texelFetch(data, worldRegion(WORLD_REGION_PLANAR_CONTROL).xy
        + ivec2(word + (next ? 4 : 0), 0), 0);
}

bool worldPlanarValid(sampler2D data, int frame, bool next) {
    vec4 header = worldPlanarWord(data, 0, next);
    int previous = (frame + 720719) % 720720;
    return header.x == 1149.0 && header.y > 0.5
        && worldDecodeInt(worldPlanarWord(data, 2, next)) == previous
        && worldDecodeUint(worldPlanarWord(data, 3, next)) == worldReadGeneration(data);
}

float worldPlanarHeight(sampler2D data, bool next) {
    return uintBitsToFloat(worldDecodeUint(worldPlanarWord(data, 1, next)));
}

// Overscan leaves room for wave distortion at the image edges. The camera's
// perspective and aspect remain those of the actual main view.
const float WORLD_PLANAR_SCALE = 0.8;

vec2 worldPlanarPixelUv(vec2 uv) {
    vec2 pixel = clamp(floor(uv * vec2(WORLD_CAPTURE_PLANAR.zw)),
        vec2(0.0), vec2(WORLD_CAPTURE_PLANAR.zw) - 1.0);
    return (pixel + 0.5) / vec2(WORLD_CAPTURE_PLANAR.zw);
}

ivec2 worldPlanarAtlasPixel(vec2 uv) {
    return WORLD_CAPTURE_PLANAR.xy + clamp(ivec2(floor(uv * vec2(WORLD_CAPTURE_PLANAR.zw))),
        ivec2(0), WORLD_CAPTURE_PLANAR.zw - 1);
}

vec2 worldPlanarAtlasUv(vec2 uv) {
    return (vec2(WORLD_CAPTURE_PLANAR.xy) + uv * vec2(WORLD_CAPTURE_PLANAR.zw))
        / float(WORLD_CAPTURE_SIDE);
}

vec2 worldPlanarMainUv(vec2 uv) {
    return (uv - 0.5) / WORLD_PLANAR_SCALE + 0.5;
}
#endif
