/* Isotropic GGX visible-normal sampling, following Heitz (JCGT 2018).
 * A view-aligned disk samples the visible microfacets. The basis switches its
 * helper axis near the pole, avoiding a singularity when looking straight up.
 */
#ifndef SIMPLE_WORLD_REFLECTION_DISTRIBUTION_GLSL
#define SIMPLE_WORLD_REFLECTION_DISTRIBUTION_GLSL

vec2 worldReflectionSequence(ivec2 pixel, int sampleIndex) {
    uint value = uint(pixel.x) * 1973u + uint(pixel.y) * 9277u + 89173u;
    value = (value ^ (value >> 16u)) * 0x7feb352du;
    value = (value ^ (value >> 15u)) * 0x846ca68bu;
    value ^= value >> 16u;
    vec2 shift = vec2(value & 65535u, value >> 16u) / 65536.0;
    float index = float(frameCounter * WORLD_REFLECTION_DIRECTIONS + sampleIndex);
    return fract(shift + index * vec2(0.754877666, 0.569840296));
}

vec3 worldReflectionDirection(vec3 incident, vec3 normal, float roughness, vec2 sampleValue) {
    vec3 axis = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(axis, normal));
    vec3 bitangent = cross(normal, tangent);
    vec3 eye = vec3(dot(-incident, tangent), dot(-incident, bitangent), dot(-incident, normal));
    float alpha = max(roughness * roughness, 0.001);
    vec3 stretched = normalize(vec3(eye.xy * alpha, max(eye.z, 0.001)));
    vec3 first = stretched.z < 0.9999
        ? normalize(cross(vec3(0.0, 0.0, 1.0), stretched)) : vec3(1.0, 0.0, 0.0);
    vec3 second = cross(stretched, first);
    float radius = sqrt(sampleValue.x);
    float angle = 6.283185307 * sampleValue.y;
    float x = radius * cos(angle);
    float y = radius * sin(angle);
    float blend = 0.5 * (1.0 + stretched.z);
    y = (1.0 - blend) * sqrt(max(0.0, 1.0 - x * x)) + blend * y;
    vec3 diskNormal = first * x + second * y
        + stretched * sqrt(max(0.0, 1.0 - x * x - y * y));
    vec3 sampled = normalize(vec3(diskNormal.xy * alpha, max(diskNormal.z, 0.0)));
    vec3 microfacet = tangent * sampled.x + bitangent * sampled.y + normal * sampled.z;
    return normalize(reflect(incident, microfacet));
}
#endif
