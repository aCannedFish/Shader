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
};

WorldModelFace worldModelFace(sampler2D resource, int index) {
    ivec4 header = worldSurfaceHeader(resource);
    int address = header.y + index * 4;
    vec4 a = worldStaticTexel(resource, address);
    vec4 b = worldStaticTexel(resource, address + 1);
    vec4 c = worldStaticTexel(resource, address + 2);
    vec4 uv = worldStaticTexel(resource, address + 3);
    int identity = int(round(a.w));
    return WorldModelFace(a.xyz, b.xyz, c.xyz, vec3(uv.xy, b.w), vec3(uv.zw, c.w),
        identity / 256, identity % 8, (identity / 16) % 16 - 1, (identity & 8) != 0);
}

bool worldUvDirectionMatches(vec2 observed, vec2 expected) {
    float denominator = length(observed) * length(expected);
    if (denominator < 1e-10) return length(observed) < 1e-7 && length(expected) < 1e-7;
    return dot(observed, expected) / denominator > 0.99999;
}

float worldFaceCornerError(WorldModelFace face, vec3 point) {
    vec3 fourth = face.a + face.c - face.b;
    return min(min(length(point - face.a), length(point - face.b)),
        min(length(point - face.c), length(point - fourth)));
}

// Match the submitted primitive to a canonical face and its exact vanilla
// displacement. Translation is inferred from corners, never from a world seed.
int worldObservedModelFace(sampler2D resource, int material, int orientation,
    vec3 a, vec3 b, vec3 c, WorldUv mapping, bool tinted, out bool hasTint,
    out WorldModelOffset displacement, out int hint, out int condition) {
    ivec2 list = worldSurfaceList(resource, material);
    bool shifted = worldSurfaceState(resource, material).w != 0;
    int selected = -1;
    int texture = -1;
    int tintRank = 2;
    bool ambiguous = false;
    hasTint = false;
    hint = 0;
    condition = 0;
    displacement = worldDecodeModelOffset(resource, material, ivec3(0));
    if (shifted) displacement.valid = false;
    for (int entry = 0; entry < 512; entry++) {
        if (entry >= list.y) break;
        int id = worldSurfaceId(resource, list.x + entry);
        WorldModelFace face = worldModelFace(resource, id);
        hasTint = hasTint || face.tint >= 0;
        if (!mapping.valid || face.face != orientation) continue;
        if (tinted && face.tint < 0) continue;
        if (!worldUvDirectionMatches(mapping.u.xy, face.u.xy)
            || !worldUvDirectionMatches(mapping.v.xy, face.v.xy)) continue;
        for (int corner = 0; corner < 4; corner++) {
            if (!shifted && corner > 0) break;
            vec3 point = corner == 0 ? face.a : corner == 1 ? face.b
                : corner == 2 ? face.c : face.a + face.c - face.b;
            WorldModelOffset offset = shifted
                ? worldFindModelOffset(resource, material, a - point, 0.0005)
                : worldDecodeModelOffset(resource, material, ivec3(0));
            if (!offset.valid) continue;
            float error = max(worldFaceCornerError(face, a - offset.value),
                max(worldFaceCornerError(face, b - offset.value),
                    worldFaceCornerError(face, c - offset.value)));
            if (error > 0.0005) continue;
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
                hint = worldSurfaceHint(resource, list.x + entry);
                condition = worldSurfaceReference(resource, list.x + entry).y;
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
