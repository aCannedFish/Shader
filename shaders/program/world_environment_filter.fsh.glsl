/* Spread sampled canopy context across the forest floor once in the cache.
 * Native sky exposure and the local ground height still reject indoor mist.
 */
/* RENDERTARGETS: 6 */
#include "/lib/world/environment.glsl"
layout(location=0) out vec4 result;

void main() {
    ivec2 local = ivec2(gl_FragCoord.xy) - worldRegion(WORLD_REGION_ENVIRONMENT_COLUMNS).xy;
    result = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0);
    if (local.x % 2 != 0 || result.a < 0.5) return;
    ivec2 column = ivec2(local.x / 2, local.y);
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            vec4 canopy = worldTerrainColumn(column + ivec2(x, y), 1);
            if (canopy.a < 0.5 || canopy.r < result.r + 1.0 || canopy.r > result.r + 32.0) continue;
            float influence = exp(-float(x * x + y * y) * 0.25);
            result.g = max(result.g, influence);
        }
    }
}
