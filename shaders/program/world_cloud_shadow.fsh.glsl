/* Build shared surface-cloud transmission before scene geometry. A paired
 * atlas copy publishes both banks; receivers outside use direct rays.
 */
/* RENDERTARGETS: 6 */
#define WORLD_BUILD_CLOUD_SHADOW (1)
// Prepare uses shadowcolor0 for geometry. Its unused colortex5 sampler gets
// cloud noise through a stage-local binding, independently of its image unit.
#define shadowcolor0 colortex5
#include "/lib/cloud_density.glsl"
#undef shadowcolor0
layout(location=0) out vec4 result;

void main() {
    ivec4 region = worldRegion(WORLD_REGION_CLOUD_SHADOW);
    vec2 local = gl_FragCoord.xy - vec2(region.xy);
    vec3 light = safeNormalize(mat3(gbufferModelViewInverse) * shadowLightPosition, vec3(0.0, 1.0, 0.0));
    float shadow = 1.0;
    if (light.y > 0.04) {
        vec2 plane = cloudShadowGridOrigin(light)
            + (local - vec2(region.zw) * 0.5) * CLOUD_SHADOW_CELL;
        shadow = cloudProjectedShadowDirect(vec3(plane.x, cloudAltitudeBounds().x, plane.y), light);
    }
    result = vec4(shadow, 0.0, 0.0, 1876.0);
}
