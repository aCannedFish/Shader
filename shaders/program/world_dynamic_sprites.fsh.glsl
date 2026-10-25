/* Cache live native model textures. Complete per-face signatures also follow
 * resource reloads; no helper supplies material identities or texture pixels.
 */
/* RENDERTARGETS: 6 */
#include "/lib/world/dynamic_identity.glsl"
uniform sampler2D colortex3;
uniform sampler2D colortex4;
layout(location=0) out vec4 result;

void main() {
    int address = int(gl_FragCoord.x) - worldRegion(WORLD_REGION_DYNAMIC_SPRITES).x;
    int face = address / 3;
    int word = address % 3;
    int model = face / 6;
    int side = model == 0 ? 6 : 8;
    int surface = face % 6;
    ivec2 sourceSize = model == 0 ? textureSize(colortex3, 0) : textureSize(colortex4, 0);
    vec2 scale = vec2(sourceSize) / vec2(32.0, 16.0);
    ivec2 offset = surface < 2 ? ivec2((surface + 1) * side, 0)
        : ivec2((surface - 2) * side, side);
    ivec2 first = ivec2(round(vec2(offset) * scale));
    ivec2 size = ivec2(round(vec2(side) * scale));
    uvec2 hash;
    bool valid = model == 0 ? worldDynamicFaceHash(colortex3, first, size, hash)
        : worldDynamicFaceHash(colortex4, first, size, hash);
    result = vec4(0.0);
    if (!valid) return;
    if (word == 0) result = worldEncodeUint(hash.x);
    if (word == 1) result = worldEncodeUint(hash.y);
    if (word == 2) result = vec4(size, model, 1647.0);
}
