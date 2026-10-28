/* Resolve each cell's three independent source transmissions once per frame.
 * Three stacked RGB slices retain glass colour without packing or quantization
 * of source identities. Material consumers interpolate only in the surface plane.
 */
/* RENDERTARGETS: 11 */
#include "/lib/conventional_lpv.glsl"
layout(location=0) out vec4 result;

void main() {
    result = vec4(0.0);
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    ivec2 size = textureSize(colortex8, 0);
    int entry = pixel.y / size.y;
    ivec2 address = ivec2(pixel.x, pixel.y % size.y);
    int index = address.x + address.y * size.x - LPV_HEADER_SIZE;
    ivec3 shape = lpvShape();
    if (entry >= 3 || index < 0 || index >= shape.x * shape.y * shape.z) return;
    int identity = int(round(texelFetch(colortex10, address, 0)[entry])) - 1;
    if (identity < 0) return;
    ivec3 source = lpvCell(identity);
    if (lpvKind(lpvVoxel(source)) != LPV_EMITTER) return;
    vec3 receiver = vec3(lpvCell(index)) + vec3(0.5);
    result = vec4(lpvVisibility(receiver, source), 1.0);
#endif
}
