/* A four-block brick can be skipped only when every contained cell is known
 * air. Partially observed bricks keep their unknown and surface counts.
 */
#include "/lib/world/lookup.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
layout(location=0) out vec4 result;

void main() {
    ivec3 shape = WORLD_FAR_SHAPE / 4;
    ivec3 brick = worldSliceCell(ivec2(gl_FragCoord.xy)
        - worldRegion(WORLD_REGION_RAY_COVERAGE).xy, shape);
    result = vec4(0.0);
    if (!worldCellValid(brick, shape)) return;
    int known = 0;
    int air = 0;
    for (int index = 0; index < 64; index++) {
        ivec3 cell = brick * 4 + ivec3(index % 4, (index / 4) % 4, index / 16);
        ivec2 pixel = worldAtlasPixel(WORLD_REGION_FAR_OPTICS,
            worldVoxelAddress(cell, WORLD_FAR_SHAPE, 0, 0));
        int state = int(round(texelFetch(colortex6, pixel, 0).w));
        if (state != WORLD_UNKNOWN) known++;
        if (state == WORLD_AIR) air++;
    }
    result = vec4(air == 64 ? 1.0 : 0.0, known, 64 - air, 1.0);
}
