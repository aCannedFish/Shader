#include "/lib/world/static.glsl"
#include "/lib/world/hue.glsl"
#include "/lib/world/coverage.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
layout(location=0) out vec4 result;

// Every observed emitter participates, independently of the shadowed-light
// selection budget. Native block-light brightness remains the surface energy.
void main() {
    result = vec4(0.0);
    ivec2 local = ivec2(gl_FragCoord.xy) - worldRegion(WORLD_REGION_HUE).xy;
    int sideX = WORLD_FAR_SHAPE.x + 2;
    int sideY = WORLD_FAR_SHAPE.y + 2;
    ivec2 slice = local / ivec2(sideX, sideY);
    ivec3 cell = ivec3(local % ivec2(sideX, sideY) - 1, slice.x + slice.y * 8);
    if (!worldCellValid(cell, WORLD_FAR_SHAPE)) return;
    ivec2 pixel = worldAtlasPixel(WORLD_REGION_FAR_OPTICS, worldVoxelAddress(cell, WORLD_FAR_SHAPE, 0, 0));
    ivec4 optics = ivec4(round(texelFetch(colortex6, pixel, 0)));
    if (optics.w == WORLD_UNKNOWN) return;
    int material = optics.x + optics.y * 256;
    WorldDefinition definition = worldReadDefinition(colortex6, material);
    if (definition.emissionLevel > 0 && ((definition.flags & 8) == 0 || (optics.z & 1024) != 0)) {
        result = vec4(definition.emission, definition.emissionLevel * 17);
        return;
    }
    if (optics.w == WORLD_SURFACE && definition.alphaType != 1 && (definition.flags & 256) != 0) return;
    ivec3 block = worldReadOrigin(colortex6, false) + cell;
    ivec2 coverage = worldCoverageAddress(block, worldReadOrigin(colortex6, false));
    int flags = int(round(texelFetch(colortex6, worldRegion(WORLD_REGION_FAR_COVERAGE).xy + coverage, 0).y));
    if ((flags & 4) == 0) return;
    vec3 colour = vec3(0.0);
    float source = 0.0;
    float total = 0.0;
    int remaining = 0;
    for (int face = 0; face < 6; face++) {
        ivec3 neighbour = cell;
        neighbour[face / 2] += face % 2 == 0 ? 1 : -1;
        vec4 hue = worldHueCell(colortex6, neighbour);
        int metadata = int(round(hue.a));
        int level = metadata / 16 - 1;
        int original = metadata & 15;
        if (level <= 0 || original <= 0) continue;
        float distance = float(original - level);
        float cutoff = 1.0 - pow(clamp(distance / float(original), 0.0, 1.0), 4.0);
        float weight = cutoff * cutoff / (1.0 + distance * distance);
        colour += hue.rgb * weight;
        source += float(original) * weight;
        total += weight;
        remaining = max(remaining, level);
    }
    if (total > 0.000001) result = vec4(colour / total, clamp(round(source / total), 1.0, 15.0) + remaining * 16);
}
