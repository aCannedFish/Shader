#ifndef SIMPLE_WORLD_UV_GLSL
#define SIMPLE_WORLD_UV_GLSL

struct WorldUv {
    vec3 u;
    vec3 v;
    bool valid;
    bool tinted;
};

int worldSurfaceAxis(vec3 normal) {
    // Cardinal ties stay stable between source triangles and analytic models.
    int axis = abs(normal.y) > abs(normal.x) + 0.001 ? 1 : 0;
    if (abs(normal.z) > abs(normal[axis]) + 0.001) axis = 2;
    return axis;
}

vec2 worldSurfaceProjection(vec3 position, int axis) {
    if (axis == 0) return position.yz;
    if (axis == 1) return position.xz;
    return position.xy;
}

WorldUv worldUvFromTriangle(vec2 a, vec2 b, vec2 c, vec2 ta, vec2 tb, vec2 tc, bool tinted) {
    vec2 first = b - a;
    vec2 second = c - a;
    float determinant = first.x * second.y - first.y * second.x;
    WorldUv result = WorldUv(vec3(0.0), vec3(0.0), false, tinted);
    if (abs(determinant) < 0.0000001) return result;
    vec2 du = vec2(tb.x - ta.x, tc.x - ta.x);
    vec2 dv = vec2(tb.y - ta.y, tc.y - ta.y);
    result.u.xy = vec2(du.x * second.y - du.y * first.y,
        first.x * du.y - second.x * du.x) / determinant;
    result.v.xy = vec2(dv.x * second.y - dv.y * first.y,
        first.x * dv.y - second.x * dv.x) / determinant;
    result.u.z = ta.x - dot(result.u.xy, a);
    result.v.z = ta.y - dot(result.v.xy, a);
    result.valid = all(lessThan(abs(result.u), vec3(2.0)))
        && all(lessThan(abs(result.v), vec3(2.0)));
    return result;
}

// Each signed coefficient uses 20 bits over [-2,2), stored as two exactly
// representable 10-bit fields. Spare bits retain validity and tint provenance.
vec2 worldEncodeUvScalar(float value) {
    uint bits = uint(clamp(round((value + 2.0) * 262144.0), 0.0, 1048575.0));
    return vec2(bits & 1023u, (bits >> 10u) & 1023u);
}

float worldDecodeUvScalar(vec2 fields) {
    uvec2 bits = uvec2(round(fields)) & uvec2(1023u);
    return float(bits.x | (bits.y << 10u)) / 262144.0 - 2.0;
}

vec4 worldEncodeUvWord(WorldUv value, int word) {
    if (!value.valid) return vec4(0.0);
    vec4 result;
    if (word == 0) {
        result = vec4(worldEncodeUvScalar(value.u.x), worldEncodeUvScalar(value.u.y));
        if (value.tinted) result.y += 1024.0;
    } else if (word == 1) {
        result = vec4(worldEncodeUvScalar(value.u.z), worldEncodeUvScalar(value.v.x));
    } else {
        result = vec4(worldEncodeUvScalar(value.v.y), worldEncodeUvScalar(value.v.z));
        result.w += 1024.0;
    }
    return result;
}

WorldUv worldDecodeUv(vec4 first, vec4 second, vec4 third) {
    return WorldUv(vec3(worldDecodeUvScalar(first.xy), worldDecodeUvScalar(first.zw),
        worldDecodeUvScalar(second.xy)), vec3(worldDecodeUvScalar(second.zw),
        worldDecodeUvScalar(third.xy), worldDecodeUvScalar(third.zw)),
        third.w >= 1024.0, first.y >= 1024.0);
}

vec2 worldSurfaceUv(WorldUv mapping, vec2 point) {
    return vec2(dot(mapping.u, vec3(point, 1.0)), dot(mapping.v, vec3(point, 1.0)));
}
#endif
