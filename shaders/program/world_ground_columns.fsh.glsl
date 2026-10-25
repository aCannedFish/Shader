/* Native ground/ceiling observations reproject by world key. Missing submission
 * retains confirmed height with an explicit historical flag, never known air.
 */
/* RENDERTARGETS: 6 */
#include "/lib/world/environment.glsl"
uniform sampler2D shadowcolor1;
layout(location=0) out vec4 result;

void main() {
    ivec2 local = ivec2(gl_FragCoord.xy) - worldRegion(WORLD_REGION_GROUND_COLUMNS).xy;
    ivec2 column = ivec2(local.x / 2, local.y);
    int field = local.x % 2;
    vec4 captured = texelFetch(shadowcolor1, WORLD_CAPTURE_ENVIRONMENT_GROUND.xy + local, 0);
    result = vec4(0.0);
    if (captured.a > 0.5) {
        result = vec4(captured.rg, 1.0, 1.0);
        return;
    }
    ivec2 control = worldRegion(WORLD_REGION_WATER_COLUMN_CONTROL).xy;
    if (texelFetch(colortex6, control + ivec2(3, 0), 0).w != 1661.0
        || worldDecodeUint(texelFetch(colortex6, control + ivec2(2, 0), 0)) != worldReadGeneration(colortex6)) return;
    ivec2 previous = ivec2(worldDecodeInt(texelFetch(colortex6, control, 0)),
        worldDecodeInt(texelFetch(colortex6, control + ivec2(1, 0), 0)));
    result = worldGroundColumn(worldReadOrigin(colortex6, false).xz + column - previous, field);
    if (result.a > 0.5) result.b = 2.0;
}
