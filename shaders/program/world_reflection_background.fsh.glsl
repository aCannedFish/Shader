/* Preserve real opaque backing samples before translucent rendering. Cutout
 * foreground does not erase the wall/mountain visible through neighbouring
 * holes. Pixel addresses are byte encoded so resizing cannot quantize them.
 */
#include "/lib/world/layout.glsl"
#include "/lib/uniforms.glsl"
/* RENDERTARGETS: 6 */
uniform sampler2D colortex0;
uniform sampler2D depthtex0;
layout(location=0) out vec4 result;

void main() {
    ivec4 field = worldRegion(WORLD_REGION_REFLECTION_BACKGROUND);
    ivec2 cell = ivec2(gl_FragCoord.xy) - field.xy;
    ivec2 size = ivec2(viewWidth, viewHeight);
    ivec2 selected = ivec2(0);
    float farthest = -1.0;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            vec2 inside = (vec2(x, y) + 0.5) / 4.0;
            ivec2 pixel = clamp(ivec2((vec2(cell) + inside) / vec2(field.zw) * vec2(size)),
                ivec2(0), size - 1);
            float flags = texelFetch(colortex0, pixel, 0).a;
            if (flags < 0.5 || flags > 1.5) continue;
            float depth = texelFetch(depthtex0, pixel, 0).r;
            if (depth < 0.999999 && depth > farthest) {
                farthest = depth;
                selected = pixel;
            }
        }
    }
    result = farthest < 0.0 ? vec4(0.0) : vec4(selected.x & 255, selected.x >> 8,
        selected.y & 255, (selected.y >> 8) + 256);
}
