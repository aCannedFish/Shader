#ifndef SIMPLE_WORLD_MODEL_SURFACE_GLSL
#define SIMPLE_WORLD_MODEL_SURFACE_GLSL
#include "/lib/world/static.glsl"
#include "/lib/world/uv.glsl"

const int WORLD_SURFACE_START = 294912;
const int WORLD_TEXTURE_UV_START = 180000;

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

ivec4 worldSurfaceHeader(sampler2D resource) {
    return ivec4(round(worldStaticTexel(resource, WORLD_SURFACE_START)));
}

ivec2 worldSurfaceList(sampler2D resource, int material) {
    ivec4 header = worldSurfaceHeader(resource);
    if (header.x <= WORLD_SURFACE_START || material <= 0 || material >= 32768) return ivec2(0);
    return ivec2(round(worldStaticTexel(resource, header.x + material).xy));
}

int worldSurfaceId(sampler2D resource, int address) {
    ivec4 header = worldSurfaceHeader(resource);
    vec4 packed = worldStaticTexel(resource, header.z + address / 4);
    return int(round(packed[address % 4]));
}

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

// Static model candidates are accepted only when the actual primitive matches
// their corners and UV orientation. Different textures on coincident faces
// remain ambiguous until their identity is established; they are never guessed.
int worldObservedModelFace(sampler2D resource, int material, int orientation,
    vec3 a, vec3 b, vec3 c, WorldUv mapping, bool tinted) {
    ivec2 list = worldSurfaceList(resource, material);
    int selected = -1;
    int texture = -1;
    for (int entry = 0; entry < 512; entry++) {
        if (entry >= list.y) break;
        int id = worldSurfaceId(resource, list.x + entry);
        WorldModelFace face = worldModelFace(resource, id);
        if (face.face != orientation) continue;
        if (tinted != (face.tint >= 0)) continue;
        float error = max(worldFaceCornerError(face, a),
            max(worldFaceCornerError(face, b), worldFaceCornerError(face, c)));
        if (error > 0.0005) continue;
        if (!worldUvDirectionMatches(mapping.u.xy, face.u.xy)
            || !worldUvDirectionMatches(mapping.v.xy, face.v.xy)) continue;
        if (selected >= 0 && texture != face.texture) return -2;
        if (selected < 0) selected = id;
        texture = face.texture;
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
