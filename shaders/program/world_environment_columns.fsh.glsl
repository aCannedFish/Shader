/* Derive the coarse mist field from native ground and canopy observations.
 * Camera rotation can change freshness, while confirmed world heights remain.
 */
/* RENDERTARGETS: 6 */
#include "/lib/world/environment.glsl"
uniform sampler2D shadowcolor1;
layout(location=0) out vec4 result;

void main() {
    ivec2 local = ivec2(gl_FragCoord.xy) - worldRegion(WORLD_REGION_ENVIRONMENT_COLUMNS).xy;
    int field = local.x % 2;
    ivec2 column = ivec2(local.x / 2, local.y);
    vec4 ground = worldGroundColumn(column * 4 + 2, 0);
    vec4 canopy = texelFetch(shadowcolor1, WORLD_CAPTURE_ENVIRONMENT_CANOPY.xy + column, 0);
    if (canopy.a < 0.5) {
        ivec2 control = worldRegion(WORLD_REGION_WATER_COLUMN_CONTROL).xy;
        if (texelFetch(colortex6, control + ivec2(3, 0), 0).w == 1661.0
            && worldDecodeUint(texelFetch(colortex6, control + ivec2(2, 0), 0)) == worldReadGeneration(colortex6)) {
            ivec2 previous = ivec2(worldDecodeInt(texelFetch(colortex6, control, 0)),
                worldDecodeInt(texelFetch(colortex6, control + ivec2(1, 0), 0)));
            ivec2 old = column + (worldReadOrigin(colortex6, false).xz - previous) / 4;
            canopy = worldTerrainColumn(old, 1);
            if (canopy.a > 0.5) canopy.a = 2.0;
        }
    }
    if (field == 1) {
        result = canopy;
        return;
    }
    result = ground.a > 0.5
        ? vec4(ground.r, canopy.a > 0.5 ? 1.0 : 0.0, ground.g, 1.0) : vec4(0.0);
}
