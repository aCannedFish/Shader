#ifndef SIMPLE_WORLD_TYPES_GLSL
#define SIMPLE_WORLD_TYPES_GLSL

// Geometry knowledge and ray termination are independent. An unobserved cell
// is unknown, not air; only an explicitly verified escape can confirm the sky.
const int WORLD_UNKNOWN = 0;
const int WORLD_AIR = 1;
const int WORLD_SURFACE = 2;
const int WORLD_WATER = 3;
const int WORLD_TRANSMISSION = 4;

const int WORLD_HIT = 0;
const int WORLD_SKY = 1;
const int WORLD_OUTSIDE = 2;
const int WORLD_EXHAUSTED = 3;
const int WORLD_INVALID = 4;
const int WORLD_UNCERTAIN = 5;

struct WorldSample {
    int state;
    int material;
    uint generation;
    vec3 albedo;
    vec2 light;
    float coverage;
};

struct WorldHit {
    int status;
    float distance;
    vec3 position;
    vec3 normal;
    vec2 uv;
    int material;
    float coverage;
    vec3 transmission;
    vec3 radiance;
    float confidence;
};

WorldSample worldUnknown(uint generation) {
    return WorldSample(WORLD_UNKNOWN, 0, generation, vec3(0.0),
        vec2(0.0), 0.0);
}

WorldHit worldInvalidHit(int status) {
    return WorldHit(status, 0.0, vec3(0.0), vec3(0.0), vec2(0.0),
        0, 0.0, vec3(1.0), vec3(0.0), 0.0);
}

#endif
