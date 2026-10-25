#include "/lib/world/solar_parameters.glsl"
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
#ifdef WORLD_PLANAR_REFLECTION
#include "/lib/world/planar.glsl"

#endif
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
#ifdef WORLD_PLANAR_REFLECTION
    if (captureRoute == 11) {
        if (!worldInsideRectangle(ivec2(gl_FragCoord.xy), WORLD_CAPTURE_PLANAR)) discard;
        if (!gl_FrontFacing) discard;
        vec4 albedo = textureLod(gtexture, sampleUv, 0.0);
        if (albedo.a < alphaTestRef) discard;
        worldOptics = vec4(pow(max(albedo.rgb * capturePayload.rgb, vec3(0.0)), vec3(2.2)), capturePayload.w);
        return;
    }
#endif
    if (captureRoute == 9 || captureRoute == 12 || captureRoute == 13) {
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
#ifdef WORLD_FULL_RENDERER
    if (captureRoute == 0) {
        vec2 distorted = (gl_FragCoord.xy - vec2(WORLD_CAPTURE_SOLAR.xy))
            / vec2(WORLD_CAPTURE_SOLAR.zw) * 2.0 - 1.0;
        vec2 original = distorted * (1.0 - SHADOW_MAP_BIAS) / max(1.0 - SHADOW_MAP_BIAS * length(distorted), 1e-8);
        float plane = uintBitsToFloat(floatBitsToUint(capturePayload.w) & ~7u);
        if (abs(capturePayload.z) > 1e-6) {
            float depth = (plane - dot(capturePayload.xy, original)) / capturePayload.z;
            gl_FragDepth = clamp(depth * 0.5 + 0.5, 0.0, 1.0);
        }
        int caster = int(floatBitsToUint(capturePayload.w) & 7u);
        worldOptics = vec4(0.0, 0.0, 0.0, 1.0);
        if (caster == 1) worldOptics = vec4(texel.rgb, 0.75);
        if (caster == 2) {
            float peak = max(texel.r, max(texel.g, texel.b));
            vec3 hue = texel.rgb / max(peak, 0.001);
            vec3 tint = (0.35 + 0.60 * peak) * (0.12 + 0.88 * pow(hue, vec3(1.5)));
            worldOptics = vec4(clamp(tint, 0.0, 1.0), 0.5);
        }
        if (caster == 3) worldOptics.a = 0.5;
        if (caster == 4) worldOptics.a = 0.25;
        return;
    }
#endif
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
