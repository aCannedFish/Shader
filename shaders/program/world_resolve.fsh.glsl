#include "/lib/world/coordinates.glsl"
#include "/lib/world/types.glsl"
#include "/lib/world/capture_layout.glsl"
/* RENDERTARGETS: 6 */
/*
const int colortex6Format = RGBA16F;
*/
const bool colortex6Clear = false;
uniform sampler2D shadowcolor0;
uniform sampler2D shadowcolor1;
uniform sampler2D colortex6;
uniform vec3 cameraPosition;
uniform int frameCounter;
layout(location=0) out vec4 result;

// Both banks receive current observations; removed or unloaded geometry cannot
// leave an old solid record. A missing observation is explicitly UNKNOWN.
void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    result = vec4(0.0);
    for (int field = 0; field < 4; field++) {
        bool nearField = field < 2;
        bool materialField = field % 2 == 0;
        int region = nearField
            ? (materialField ? WORLD_REGION_NEAR_MATERIAL : WORLD_REGION_NEAR_OPTICS)
            : (materialField ? WORLD_REGION_FAR_MATERIAL : WORLD_REGION_FAR_OPTICS);
        ivec4 rectangle = worldRegion(region);
        if (!worldInsideRectangle(pixel, rectangle)) continue;
        ivec3 shape = nearField ? WORLD_NEAR_SHAPE : WORLD_FAR_SHAPE;
        ivec3 cell = worldSliceCell(pixel - rectangle.xy, shape);
        ivec2 rawPixel = worldCapturePixel(nearField, cell);
        if (rawPixel.x < 0) return;
        vec4 raw = texelFetch(shadowcolor1, rawPixel, 0);
        if (raw.w < 16.5 || raw.w > 22.5) return;
        if (materialField) {
            result = texelFetch(shadowcolor0, rawPixel, 0);
        } else {
            int material = int(round(raw.x));
            int state = material == 100 ? WORLD_WATER
                : material == 110 ? WORLD_TRANSMISSION : WORLD_SURFACE;
            result = vec4(material % 256, material / 256, round(raw.w) - 17.0, state);
        }
        return;
    }
    // Integer origins and frame IDs are byte encoded for half-float precision.
    ivec4 header = worldRegion(WORLD_REGION_HEADER);
    if (!worldInsideRectangle(pixel, header)) return;
    ivec2 local = pixel - header.xy;
    if (local.y != 0) return;
    if (local.x == 0) result = worldEncodeUint(WORLD_LAYOUT_SIGNATURE);
    if (local.x == 1) result = worldEncodeInt(frameCounter);
    if (local.x >= 2 && local.x < 8) {
        bool nearField = local.x < 5;
        ivec3 shape = nearField ? WORLD_NEAR_SHAPE : WORLD_FAR_SHAPE;
        ivec3 origin = worldAlignedOrigin(cameraPosition, shape, nearField ? 2 : 1, 4);
        int axis = nearField ? local.x - 2 : local.x - 5;
        result = worldEncodeInt(origin[axis]);
    }
}
