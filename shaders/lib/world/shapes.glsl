#ifndef SIMPLE_WORLD_SHAPES_GLSL
#define SIMPLE_WORLD_SHAPES_GLSL

struct WorldBoxInterval {
    bool valid;
    float enter;
    float leave;
    vec3 enterNormal;
    vec3 leaveNormal;
};

// Parallel axes are handled explicitly: zero times infinity must never turn
// an aligned wall, pane or seam into an invalid intersection.
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

// A shape occupies two texels per box, storing normalized local bounds. The
// caller supplies the first texel and row width from the shared resource table.
vec3 worldShapeBound(sampler2D table, int first, int box, bool upper, int width, ivec2 base) {
    int index = first + box * 2 + int(upper);
    return texelFetch(table, base + ivec2(index % width, index / width), 0).xyz;
}

struct WorldShapeHit {
    bool valid;
    float distance;
    vec3 normal;
    int box;
};

WorldShapeHit worldIntersectShape(sampler2D table, int first, int count, int width, ivec2 base,
    vec3 origin, vec3 direction, float minimum, float maximum) {
    WorldShapeHit nearest = WorldShapeHit(false, maximum, vec3(0.0), -1);
    vec3 start = origin + direction * minimum;
    bool insideUnion = false;
    for (int box = 0; box < 32; box++) {
        if (box >= count) break;
        vec3 low = worldShapeBound(table, first, box, false, width, base);
        vec3 high = worldShapeBound(table, first, box, true, width, base);
        insideUnion = insideUnion || all(greaterThan(start, low))
            && all(lessThan(start, high));
    }
    for (int box = 0; box < 32; box++) {
        if (box >= count) break;
        vec3 low = worldShapeBound(table, first, box, false, width, base);
        vec3 high = worldShapeBound(table, first, box, true, width, base);
        WorldBoxInterval interval = worldBoxInterval(origin, direction, low, high);
        if (!interval.valid || interval.leave < minimum) continue;
        bool inside = insideUnion;
        float distance = inside ? interval.leave : interval.enter;
        if (distance < minimum || distance >= nearest.distance) continue;
        if (count > 1) {
            // Entries approached from another component and exits entering
            // another component are internal seams, not visible boundaries.
            float side = inside ? 1.0 : -1.0;
            vec3 beyond = origin + direction * (distance + side * 0.00002);
            bool interior = false;
            for (int other = 0; other < 32; other++) {
                if (other >= count) break;
                vec3 otherLow = worldShapeBound(table, first, other, false, width, base);
                vec3 otherHigh = worldShapeBound(table, first, other, true, width, base);
                interior = interior || all(greaterThan(beyond, otherLow))
                    && all(lessThan(beyond, otherHigh));
            }
            if (interior) continue;
        }
        nearest = WorldShapeHit(true, distance,
            inside ? interval.leaveNormal : interval.enterNormal, box);
    }
    return nearest;
}
#endif
