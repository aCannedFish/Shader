/* Shade the complete reflected view, including its actual background. Once
 * geometry is rasterized from the mirror camera, filtering across leaf holes
 * combines the leaf with that same view's wall/sky, not a guessed main view.
 */
#include "/lib/world/planar.glsl"
#include "/lib/world/reflection_query.glsl"
#include "/lib/sky.glsl"
#include "/lib/clouds.glsl"
/* RENDERTARGETS: 6 */
layout(location=0) out vec4 result;

vec3 mirrorDirection(vec2 uv, mat4 inverseProjection) {
    vec4 view = inverseProjection * vec4(worldPlanarMainUv(uv) * 2.0 - 1.0, 1.0, 1.0);
    vec3 ray = normalize(mat3(gbufferModelViewInverse) * view.xyz);
    ray.y = -ray.y;
    return ray;
}

vec3 mirrorNormal(int metadata) {
    vec2 encoded = vec2(metadata & 255, (metadata >> 8) & 255) / 255.0 * 2.0 - 1.0;
    vec3 normal = vec3(encoded, 1.0 - abs(encoded.x) - abs(encoded.y));
    if (normal.z < 0.0) {
        vec2 signValue = vec2(normal.x >= 0.0 ? 1.0 : -1.0, normal.y >= 0.0 ? 1.0 : -1.0);
        normal.xy = (1.0 - abs(normal.yx)) * signValue;
    }
    return normalize(normal);
}

void main() {
    result = vec4(0.0);
    if (!worldPlanarValid(colortex6, frameCounter, false)) return;
    ivec2 pixel = ivec2(gl_FragCoord.xy) - worldRegion(WORLD_REGION_PLANAR_RADIANCE).xy;
    ivec2 sourcePixel = WORLD_CAPTURE_PLANAR.xy + pixel;
    vec2 uv = (vec2(pixel) + 0.5) / vec2(WORLD_CAPTURE_PLANAR.zw);
    vec4 raw = texelFetch(shadowcolor1, sourcePixel, 0);
    mat4 inverseProjection = inverse(gbufferPreviousProjection);
    float depth = texelFetch(shadowtex0, sourcePixel, 0).r;
    if (raw.a < 0.5 || depth >= 0.999999) {
        vec3 direction = mirrorDirection(uv, inverseProjection);
        vec4 cloud = cloudEnvironment(direction);
        result = vec4(cloud.rgb + (skyAtmosphereRadiance(direction) + skyStars(direction)) * (1.0 - cloud.a), 0.0);
        return;
    }
    vec4 view = inverseProjection * vec4(worldPlanarMainUv(uv) * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec3 relative = (gbufferModelViewInverse * vec4(view.xyz / view.w, 1.0)).xyz;
    float height = worldPlanarHeight(colortex6, false);
    relative.y = 2.0 * (height - cameraPosition.y) - relative.y;
    int metadata = int(round(raw.a));
    int packedLight = metadata >> 16;
    vec2 light = vec2(packedLight & 15, packedLight >> 4) / 15.0;
    WorldSurfaceMaterial material = WorldSurfaceMaterial(raw.rgb, vec3(0.0), vec3(0.0), 1.0, 0, true, true);
    vec3 radiance = worldReflectionRadiance(worldPosition(relative, cameraPosition), mirrorNormal(metadata),
        light, material, worldReadDefinition(colortex6, 0));
    result = vec4(radiance, 1.0);
}
