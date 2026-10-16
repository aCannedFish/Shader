/* Piecewise-constant RGB absorption integrated over exact grid and pane segments. */
uniform sampler2D uAbsorption;

vec4 opticalMaterial(ivec3 cell) {
    return insideVolume(cell) ? texelFetch(uAbsorption, voxelPixel(cell), 0) : vec4(0.0);
}

float boxPath(vec3 origin, vec3 inverseRay, vec3 lower, vec3 upper, float start, float end) {
    vec3 a = (lower - origin) * inverseRay;
    vec3 b = (upper - origin) * inverseRay;
    vec3 near = min(a, b);
    vec3 far = max(a, b);
    float entry = max(start, max(near.x, max(near.y, near.z)));
    float exit = min(end, min(far.x, min(far.y, far.z)));
    return max(exit - entry, 0.0);
}

// Disjoint central post and connected arms match the actual 1/8-block pane shape.
float materialPath(vec4 material, ivec3 cell, vec3 origin, vec3 inverseRay, float start, float end) {
    if (material.a < 0.5) {
        return 0.0;
    }
    if (material.a < 1.5) {
        return end - start;
    }
    vec3 p = vec3(cell);
    const float low = 0.4375;
    const float high = 0.5625;
    float distance = boxPath(origin, inverseRay, p + vec3(low, 0.0, low),
        p + vec3(high, 1.0, high), start, end);
    int connections = int(material.a + 0.5) - 2;
    if ((connections & 1) != 0) {
        distance += boxPath(origin, inverseRay, p + vec3(high, 0.0, low), p + vec3(1.0, 1.0, high), start, end);
    }
    if ((connections & 2) != 0) {
        distance += boxPath(origin, inverseRay, p + vec3(0.0, 0.0, low), p + vec3(low, 1.0, high), start, end);
    }
    if ((connections & 4) != 0) {
        distance += boxPath(origin, inverseRay, p + vec3(low, 0.0, high), p + vec3(high, 1.0, 1.0), start, end);
    }
    if ((connections & 8) != 0) {
        distance += boxPath(origin, inverseRay, p + vec3(low, 0.0, 0.0), p + vec3(high, 1.0, low), start, end);
    }
    return distance;
}

// Amanatides-Woo traversal; tied axes advance together, including negative rays.
vec3 traceTransmission(vec3 origin, vec3 target) {
    vec3 delta = target - origin;
    float distance = length(delta);
    if (distance < 0.0001) {
        return vec3(1.0);
    }
    vec3 ray = delta / distance;
    vec3 safeRay = mix(min(ray, vec3(-0.000001)), max(ray, vec3(0.000001)), greaterThanEqual(ray, vec3(0.0)));
    vec3 inverseRay = 1.0 / safeRay;
    vec3 a = -origin * inverseRay;
    vec3 b = (vec3(uSize) - origin) * inverseRay;
    vec3 near = min(a, b);
    vec3 far = max(a, b);
    float start = max(0.0, max(near.x, max(near.y, near.z)));
    float end = min(distance, min(far.x, min(far.y, far.z)));
    if (end <= start) {
        return vec3(1.0);
    }
    ivec3 cell = ivec3(floor(origin + ray * (start + 0.0001)));
    ivec3 step = ivec3(sign(ray));
    vec3 boundary = vec3(cell) + max(sign(ray), vec3(0.0));
    vec3 next = (boundary - origin) * inverseRay;
    next = mix(next, vec3(1e20), lessThan(abs(ray), vec3(0.000001)));
    vec3 interval = abs(inverseRay);
    vec3 opticalDepth = vec3(0.0);
    // At most three crossings per axis cell, for the supported 48-cubed volume.
    for (int index = 0; index < 148; index++) {
        if (!insideVolume(cell) || start >= end) {
            break;
        }
        float exit = min(end, min(next.x, min(next.y, next.z)));
        vec4 material = opticalMaterial(cell);
        opticalDepth += material.rgb * materialPath(material, cell, origin, inverseRay, start, exit);
        if (all(greaterThan(opticalDepth, vec3(10.0)))) {
            break;
        }
        bvec3 crossed = lessThanEqual(next, vec3(exit + 0.00001));
        cell += ivec3(crossed) * step;
        next += vec3(crossed) * interval;
        start = exit;
    }
    return exp(-opticalDepth);
}
