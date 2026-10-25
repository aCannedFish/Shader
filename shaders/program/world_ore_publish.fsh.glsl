/* Publish source keys and UVs after all dependent mask texels are complete. */
/* RENDERTARGETS: 6 */
#include "/lib/world/ore_cache.glsl"
layout(location=0) out vec4 result;

void main() {
    ivec2 local = ivec2(gl_FragCoord.xy) - worldRegion(WORLD_REGION_ORE_METADATA).xy;
    result = texelFetch(colortex6, worldRegion(WORLD_REGION_ORE_PENDING).xy + local, 0);
}
