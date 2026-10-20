/* Small analytic fields shared by sky emission and near-ground media. No
 * texture sampler or screen derivative is needed; periodic fields keep terrain
 * patterns stable when the companion rebases its camera-centred grid.
 */
#ifndef LIB_ATMOSPHERE_NOISE_GLSL
#define LIB_ATMOSPHERE_NOISE_GLSL
float atmosphereHash(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

float atmosphereNoise2(vec2 p, float period) {
    vec2 cell = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    vec2 a = mod(cell, period);
    vec2 b = mod(cell + 1.0, period);
    float lower = mix(atmosphereHash(vec3(a, 0.0)), atmosphereHash(vec3(b.x, a.y, 0.0)), f.x);
    float upper = mix(atmosphereHash(vec3(a.x, b.y, 0.0)), atmosphereHash(vec3(b, 0.0)), f.x);
    return mix(lower, upper, f.y);
}

float atmosphereNoise3(vec3 p) {
    vec3 cell = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(atmosphereHash(cell), atmosphereHash(cell + vec3(1.0, 0.0, 0.0)), f.x);
    float b = mix(atmosphereHash(cell + vec3(0.0, 1.0, 0.0)), atmosphereHash(cell + vec3(1.0, 1.0, 0.0)), f.x);
    float c = mix(atmosphereHash(cell + vec3(0.0, 0.0, 1.0)), atmosphereHash(cell + vec3(1.0, 0.0, 1.0)), f.x);
    float d = mix(atmosphereHash(cell + vec3(0.0, 1.0, 1.0)), atmosphereHash(cell + vec3(1.0, 1.0, 1.0)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}
#endif
