/* Preserve confirmed native water planes by world column. Current visibility
 * affects freshness, not interface height. Rebase/teleport/resource epochs
 * reject the old cache; retained planes expose their last observed frame.
 */
/* RENDERTARGETS: 6 */
#include "/lib/world/environment.glsl"
uniform sampler2D shadowcolor1;
layout(location=0) out vec4 result;

void main() {
    ivec2 local = ivec2(gl_FragCoord.xy) - worldRegion(WORLD_REGION_WATER_COLUMNS).xy;
    ivec2 column = ivec2(local.x / 3, local.y);
    int word = local.x % 3;
    vec4 plane = texelFetch(shadowcolor1, WORLD_CAPTURE_WATER_COLUMNS.xy + column, 0);
    result = vec4(0.0);
    if (plane.w > 0.5) {
        if (word == 0) result = vec4(floor(plane.x), round(fract(plane.x) * 2047.0), 0.0, 1.0);
        if (word == 1) result = vec4(plane.yz, plane.w, 1.0);
        if (word == 2) result = worldEncodeInt(frameCounter);
        return;
    }
    ivec2 control = worldRegion(WORLD_REGION_WATER_COLUMN_CONTROL).xy;
    if (texelFetch(colortex6, control + ivec2(3, 0), 0).w != 1661.0
        || worldDecodeUint(texelFetch(colortex6, control + ivec2(2, 0), 0)) != worldReadGeneration(colortex6)) return;
    ivec2 previousOrigin = ivec2(worldDecodeInt(texelFetch(colortex6, control, 0)),
        worldDecodeInt(texelFetch(colortex6, control + ivec2(1, 0), 0)));
    ivec2 old = worldReadOrigin(colortex6, false).xz + column - previousOrigin;
    result = worldWaterColumn(old, word);
    if (word == 1 && result.z > 0.5) result.w = 2.0;
}
