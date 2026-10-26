#ifndef SIMPLE_WORLD_MODEL_SURFACE_GLSL
#define SIMPLE_WORLD_MODEL_SURFACE_GLSL
#include "/lib/world/surface_table.glsl"
#include "/lib/world/uv.glsl"
#include "/lib/world/model_offset.glsl"

struct WorldModelFace {
    vec3 a;
    vec3 b;
    vec3 c;
    vec3 u;
    vec3 v;
    int texture;
    int face;
    int tint;
    bool shaded;
    bool airSeed;
};

// The first record contains orientation/tint. Capture can reject unrelated
// faces before fetching their geometry and UV records.
WorldModelFace worldModelFace(sampler2D staticData, int address, vec4 a) {
    vec4 b = worldStaticTexel(staticData, address + 1);
    vec4 c = worldStaticTexel(staticData, address + 2);
    vec4 uv = worldStaticTexel(staticData, address + 3);
    int encoded = int(round(a.w));
    int identity = encoded & 0x7fffff;
    return WorldModelFace(a.xyz, b.xyz, c.xyz, vec3(uv.xy, b.w), vec3(uv.zw, c.w),
        identity / 256, identity % 8, (identity / 16) % 16 - 1, (identity & 8) != 0, (encoded & 0x800000) != 0);
}

WorldModelFace worldModelFace(sampler2D staticData, int index) {
    int address = worldSurfaceHeader(staticData).y + index * 4;
    return worldModelFace(staticData, address, worldStaticTexel(staticData, address));
}

bool worldUvDirectionMatches(vec2 observed, vec2 expected) {
    float denominator = length(observed) * length(expected);
    if (denominator < 1e-10) return length(observed) < 1e-7 && length(expected) < 1e-7;
    return dot(observed, expected) / denominator > 0.99999;
}

float worldFaceCornerErrorSquared(WorldModelFace face, vec3 point) {
    vec3 fourth = face.a + face.c - face.b;
    vec3 a = point - face.a;
    vec3 b = point - face.b;
    vec3 c = point - face.c;
    vec3 d = point - fourth;
    return min(min(dot(a, a), dot(b, b)), min(dot(c, c), dot(d, d)));
}

// Match the submitted primitive to a canonical face and its exact vanilla
// displacement. Translation is inferred from corners, never from a world seed.
int worldObservedModelFace(sampler2D staticData, int material, int orientation,
    vec3 a, vec3 b, vec3 c, WorldUv mapping, bool tinted, out bool hasTint,
    out WorldModelOffset displacement, out int hint, out int condition) {
    ivec2 list = worldSurfaceList(staticData, material);
    bool shifted = worldSurfaceState(staticData, material).w != 0;
    int selected = -1;
    int texture = -1;
    int tintRank = 2;
    bool ambiguous = false;
    hasTint = false;
    hint = 0;
    condition = 0;
    displacement = worldDecodeModelOffset(staticData, material, ivec3(0));
    WorldModelOffset fixedOffset = displacement;
    if (shifted) displacement.valid = false;
    int faceBase = worldSurfaceHeader(staticData).y;
    for (int entry = 0; entry < 512; entry++) {
        if (entry >= list.y) break;
        int id = worldSurfaceId(staticData, list.x + entry);
        int address = faceBase + id * 4;
        vec4 firstRecord = worldStaticTexel(staticData, address);
        int identity = int(round(firstRecord.w)) & 0x7fffff;
        int tint = (identity / 16) % 16 - 1;
        hasTint = hasTint || tint >= 0;
        if (!mapping.valid || identity % 8 != orientation) continue;
        if (tinted && tint < 0) continue;
        WorldModelFace face = worldModelFace(staticData, address, firstRecord);
        if (!worldUvDirectionMatches(mapping.u.xy, face.u.xy)
            || !worldUvDirectionMatches(mapping.v.xy, face.v.xy)) continue;
        for (int corner = 0; corner < 4; corner++) {
            if (!shifted && corner > 0) break;
            vec3 point = corner == 0 ? face.a : corner == 1 ? face.b
                : corner == 2 ? face.c : face.a + face.c - face.b;
            WorldModelOffset offset = shifted
                ? worldFindModelOffset(staticData, material, a - point, 0.0005)
                : fixedOffset;
            if (!offset.valid) continue;
            float errorSquared = max(worldFaceCornerErrorSquared(face, a - offset.value),
                max(worldFaceCornerErrorSquared(face, b - offset.value),
                    worldFaceCornerErrorSquared(face, c - offset.value)));
            if (errorSquared > 0.0005 * 0.0005) continue;
            // A neutral submitted layer prefers an untinted template. Only
            // fall back to a white-tinted face if no untinted face matches.
            int rank = !tinted && face.tint >= 0 ? 1 : 0;
            if (rank > tintRank) continue;
            if (rank < tintRank) {
                selected = -1;
                texture = -1;
                ambiguous = false;
                tintRank = rank;
            }
            if (selected >= 0 && (texture != face.texture
                || any(notEqual(offset.code, displacement.code)))) ambiguous = true;
            if (selected < 0) {
                selected = id;
                displacement = offset;
                hint = worldSurfaceHint(staticData, list.x + entry);
                condition = worldSurfaceReference(staticData, list.x + entry).y;
            }
            texture = face.texture;
        }
    }
    if (ambiguous) {
        hint = 0;
        displacement.valid = false;
        return -2;
    }
    return selected;
}

bool worldPointOnModelFace(WorldModelFace face, vec3 point, vec3 normal) {
    vec3 first = face.b - face.a;
    vec3 second = face.c - face.b;
    vec3 geometric = normalize(cross(first, second));
    if (dot(geometric, normal) < 0.9999) return false;
    vec3 offset = point - face.a;
    if (abs(dot(offset, geometric)) > 0.0005) return false;
    float u = dot(offset, first) / dot(first, first);
    float v = dot(offset, second) / dot(second, second);
    return min(u, v) >= -0.0005 && max(u, v) <= 1.0005;
}
#endif
