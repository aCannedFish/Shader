#ifndef SIMPLE_WORLD_SHAPES_GLSL
#define SIMPLE_WORLD_SHAPES_GLSL

struct WorldBoxInterval {
    bool valid;
    float enter;
    float leave;
    vec3 enterNormal;
    vec3 leaveNormal;
};

// Parallel axes are explicit: zero times infinity cannot invalidate an aligned
// wall or a zero-thickness model plane.
WorldBoxInterval worldBoxInterval(vec3 origin, vec3 direction, vec3 low, vec3 high) {
    WorldBoxInterval hit = WorldBoxInterval(true, -1e20, 1e20, vec3(0.0), vec3(0.0));
    for (int axis = 0; axis < 3; axis++) {
        if (abs(direction[axis]) < 1e-8) {
            if (origin[axis] < low[axis] || origin[axis] > high[axis]) hit.valid = false;
            continue;
        }
        float first = (low[axis] - origin[axis]) / direction[axis];
        float second = (high[axis] - origin[axis]) / direction[axis];
        float nearDistance = min(first, second);
        float farDistance = max(first, second);
        vec3 normal = vec3(0.0);
        normal[axis] = direction[axis] > 0.0 ? -1.0 : 1.0;
        if (nearDistance > hit.enter) {
            hit.enter = nearDistance;
            hit.enterNormal = normal;
        }
        if (farDistance < hit.leave) {
            hit.leave = farDistance;
            hit.leaveNormal = -normal;
        }
    }
    hit.valid = hit.valid && hit.leave >= max(hit.enter, 0.0);
    return hit;
}

struct WorldModelPart {
    vec3 low;
    vec3 high;
    vec3 pivot;
    int rotation;
};

vec4 worldShapeRecord(sampler2D table, int index, int width, ivec2 base) {
    return texelFetch(table, base + ivec2(index % width, index / width), 0);
}

WorldModelPart worldShapePart(sampler2D table, int first, int part, int width,
    int stride, ivec2 base) {
    int index = first + part * stride;
    vec4 rotation = stride >= 3 ? worldShapeRecord(table, index + 2, width, base) : vec4(0.0);
    return WorldModelPart(worldShapeRecord(table, index, width, base).xyz,
        worldShapeRecord(table, index + 1, width, base).xyz, rotation.xyz, int(round(rotation.w)));
}

// Vanilla model elements use 0, +/-22.5 or +/-45 degrees. A cardinal state
// rotation changes only the signed element axis; the build tool encodes it here.
vec2 worldPartSinCos(int code) {
    int angle = code % 5;
    if (angle == 1) return vec2(0.3826834324, 0.9238795325);
    if (angle == 2) return vec2(-0.3826834324, 0.9238795325);
    if (angle == 3) return vec2(0.7071067812, 0.7071067812);
    if (angle == 4) return vec2(-0.7071067812, 0.7071067812);
    return vec2(0.0, 1.0);
}

vec3 worldPartRotate(vec3 value, int axis, vec2 sineCosine) {
    int first = (axis + 1) % 3;
    int second = (axis + 2) % 3;
    vec3 result = value;
    result[first] = sineCosine.y * value[first] - sineCosine.x * value[second];
    result[second] = sineCosine.x * value[first] + sineCosine.y * value[second];
    return result;
}

vec3 worldPartLocalVector(WorldModelPart part, vec3 value) {
    if (part.rotation == 0) return value;
    int axis = (part.rotation % 15) / 5;
    vec2 angle = worldPartSinCos(part.rotation);
    vec3 local = worldPartRotate(value, axis, vec2(-angle.x, angle.y));
    if (part.rotation >= 15) {
        local[(axis + 1) % 3] *= angle.y;
        local[(axis + 2) % 3] *= angle.y;
    }
    return local;
}

vec3 worldPartLocalPoint(WorldModelPart part, vec3 value) {
    return worldPartLocalVector(part, value - part.pivot) + part.pivot;
}

vec3 worldPartNormal(WorldModelPart part, vec3 value) {
    if (part.rotation == 0) return value;
    return worldPartRotate(value, (part.rotation % 15) / 5, worldPartSinCos(part.rotation));
}

bool worldPartContains(WorldModelPart part, vec3 point) {
    vec3 local = worldPartLocalPoint(part, point);
    return all(greaterThan(local, part.low)) && all(lessThan(local, part.high));
}

struct WorldShapeHit {
    bool valid;
    float distance;
    vec3 normal;
    int box;
};

WorldShapeHit worldIntersectShape(sampler2D table, int first, int count, int width,
    int stride, ivec2 base, vec3 origin, vec3 direction, float minimum, float maximum) {
    WorldShapeHit nearest = WorldShapeHit(false, maximum, vec3(0.0), -1);
    // Cubes and single planes avoid the union passes used by stairs and models.
    if (count == 1) {
        WorldModelPart part = worldShapePart(table, first, 0, width, stride, base);
        WorldBoxInterval interval = worldBoxInterval(worldPartLocalPoint(part, origin),
            worldPartLocalVector(part, direction), part.low, part.high);
        if (!interval.valid || interval.leave < minimum) return nearest;
        bool inside = interval.enter < minimum;
        float distance = inside ? interval.leave : interval.enter;
        if (distance < minimum || distance >= maximum) return nearest;
        return WorldShapeHit(true, distance,
            worldPartNormal(part, inside ? interval.leaveNormal : interval.enterNormal), 0);
    }
    vec3 start = origin + direction * minimum;
    bool insideUnion = false;
    for (int box = 0; box < 64; box++) {
        if (box >= count) break;
        insideUnion = insideUnion || worldPartContains(worldShapePart(table, first, box, width, stride, base), start);
    }
    for (int box = 0; box < 64; box++) {
        if (box >= count) break;
        WorldModelPart part = worldShapePart(table, first, box, width, stride, base);
        WorldBoxInterval interval = worldBoxInterval(worldPartLocalPoint(part, origin),
            worldPartLocalVector(part, direction), part.low, part.high);
        if (!interval.valid || interval.leave < minimum) continue;
        float distance = insideUnion ? interval.leave : interval.enter;
        if (distance < minimum || distance >= nearest.distance) continue;
        vec3 beyond = origin + direction * (distance + (insideUnion ? 0.00002 : -0.00002));
        bool interior = false;
        for (int other = 0; other < 64; other++) {
            if (other >= count) break;
            interior = interior || worldPartContains(worldShapePart(table, first, other, width, stride, base), beyond);
        }
        if (interior) continue;
        nearest = WorldShapeHit(true, distance,
            worldPartNormal(part, insideUnion ? interval.leaveNormal : interval.enterNormal), box);
    }
    return nearest;
}
#endif
