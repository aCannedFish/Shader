/* RENDERTARGETS: 0,1 */
#include "/lib/world/raw_uv.glsl"
#include "/lib/world/raw_observation.glsl"
#include "/lib/world/coordinates.glsl"
#include "/lib/world/capture_layout.glsl"
#include "/lib/world/point_shadow.glsl"
/*
const int shadowcolor0Format = RGBA32F;
const int shadowcolor1Format = RGBA32F;
*/
uniform sampler2D gtexture;
uniform float alphaTestRef;
in vec2 sampleUv;
flat in int captureRoute;
flat in vec4 capturePayload;
layout(location=0) out vec4 worldMaterial;
layout(location=1) out vec4 worldOptics;

void main() {
    gl_FragDepth = gl_FragCoord.z;
    worldMaterial = vec4(0.0);
    worldOptics = vec4(0.0);
    if (captureRoute == 9) {
        worldOptics = capturePayload;
        return;
    }
    if (captureRoute == 3 || captureRoute == 5 || captureRoute == 10) {
        worldMaterial = capturePayload;
        return;
    }
    if (captureRoute == 2) {
#ifdef WORLD_PACKED_UV
        worldOptics = capturePayload;
#else
        WorldUv mapping = worldRawDecodeUv(capturePayload);
        worldMaterial = vec4(mapping.u, mapping.valid ? 517.0 : 0.0);
        worldOptics = vec4(mapping.v, mapping.tinted ? 518.0 : 517.0);
#endif
        return;
    }
    if (captureRoute == 1 || captureRoute == 8) {
#ifdef WORLD_SHADOW_DIAGNOSTIC
        if (captureRoute == 1) worldMaterial = vec4(0.0, round(sampleUv.x), 1.0, 0.0);
#endif
        if (captureRoute == 8) {
            if (!worldInsideRectangle(ivec2(gl_FragCoord.xy), WORLD_CAPTURE_FAR)) discard;
            WorldObservation proxy = worldDecodeObservation(capturePayload);
            ivec3 bounds = ivec3(round(proxy.tint * 255.0));
            ivec2 extent = ivec2(bounds.z % 16, bounds.z / 16) + 1;
            ivec2 cell = (ivec2(gl_FragCoord.xy) - WORLD_CAPTURE_FAR.xy) % WORLD_FAR_SHAPE.xy;
            if (any(lessThan(cell, bounds.xy)) || any(greaterThanEqual(cell, bounds.xy + extent))) discard;
            worldMaterial = vec4(0.0, round(sampleUv.x), 1.0, 0.0);
        }
#ifdef WORLD_PACKED_OBSERVATION
        worldOptics = capturePayload;
#else
        WorldObservation observation = worldDecodeObservation(capturePayload);
        worldMaterial = vec4(observation.albedo, observation.light);
        worldOptics = vec4(observation.material, sampleUv, observation.face + 17);
#endif
        return;
    }
    if (captureRoute == 0 && !worldInsideRectangle(ivec2(gl_FragCoord.xy), WORLD_CAPTURE_SOLAR)) discard;
    vec4 texel = textureLod(gtexture, sampleUv, 0.0);
    if (texel.a < alphaTestRef) discard;
    if (captureRoute == 4) {
        ivec2 pixel = ivec2(gl_FragCoord.xy) - WORLD_CAPTURE_POINTS.xy;
        if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, WORLD_CAPTURE_POINTS.zw))) discard;
        ivec2 tileCell = pixel / WORLD_POINT_SHADOW_SIDE;
        int tile = tileCell.x + tileCell.y * 24;
        if (tile != worldShadowPlaneTile(capturePayload.w)) discard;
        vec2 uv = (vec2(pixel % WORLD_POINT_SHADOW_SIDE) + 0.5 - 1.0) / float(WORLD_POINT_SHADOW_SIDE - 2);
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) discard;
        vec3 ray = worldPointFaceDirection(tile % 6, uv);
        float denominator = dot(capturePayload.xyz, ray);
        float distance = worldShadowPlaneDistance(capturePayload.w) / denominator;
        if (abs(denominator) < 1e-8 || distance <= 0.0 || distance >= 1.0) discard;
        int axis = worldSurfaceAxis(capturePayload.xyz);
        bool cardinal = abs(capturePayload[axis]) > 0.9999;
        float plane = cardinal ? worldShadowPlaneDistance(capturePayload.w) / capturePayload[axis] : 0.0;
        worldOptics = vec4(1.0 - distance, 0.0, cardinal ? float(axis + 1) * 0.25 : 1.0, plane);
        gl_FragDepth = distance;
        return;
    }
    worldMaterial.a = 1.0;
}
