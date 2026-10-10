/* Sky lookup, circular celestial bodies and a continuous stellar background. */
#ifndef LIB_SKY_GLSL
#define LIB_SKY_GLSL

#include "/lib/atmosphere.glsl"
#include "/lib/color_space.glsl"

uniform sampler2D colortex3;
#include "/lib/sky_noise.glsl"

// Vanilla quads use half-sizes 30 and 20 at distance 100; the visible bright
// cores occupy about one quarter of their texture widths. Circular bodies use
// the corresponding apparent core widths, while retaining lunar surface detail.
const float SKY_SUN_RADIUS = 0.075;
const float SKY_MOON_RADIUS = 0.050;

vec3 skyViewDirection(vec2 uv) {
    vec4 ray = gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
    return safeNormalize(mat3(gbufferModelViewInverse) * ray.xyz, vec3(0.0, 1.0, 0.0));
}

vec2 skyLookupCoordinate(vec3 direction) {
    float azimuth = atan(direction.z, direction.x) / (2.0 * PI) + 0.5;
    float elevation = 0.5 + 0.5 * sign(direction.y) * sqrt(abs(direction.y));
    return vec2(azimuth, elevation);
}

vec3 skyLookupDirection(vec2 uv) {
    float azimuth = (uv.x - 0.5) * 2.0 * PI;
    float h = uv.y * 2.0 - 1.0;
    float elevation = sign(h) * h * h;
    float horizontal = sqrt(max(1.0 - elevation * elevation, 0.0));
    return vec3(cos(azimuth) * horizontal, elevation, sin(azimuth) * horizontal);
}

vec3 skyAtmosphereRadiance(vec3 direction) {
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0));
    vec2 uv = clamp(skyLookupCoordinate(direction), 0.5 / size, 1.0 - 0.5 / size);
    return texture2D(colortex3, uv * size / vec2(viewWidth, viewHeight)).rgb;
}

float skyHash(vec2 p) {
    vec3 value = fract(vec3(p.x, p.y, p.x) * 0.1031);
    value += dot(value, value.yzx + 33.33);
    return fract((value.x + value.y) * value.z);
}

// Stars use spherical cells. Angular derivatives are taken from the ray itself,
// so the longitude seam cannot create a bright vertical line.
vec3 skyStars(vec3 direction) {
    float night = 1.0 - smoothstep(-0.15, -0.03, skySunDirection().y);
    if (night < 0.001 || direction.y < 0.0) {
        return vec3(0.0);
    }
    vec2 coordinate = vec2(atan(direction.z, direction.x) / (2.0 * PI) + 0.5,
                           asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5) * vec2(2048.0, 1024.0);
    vec2 cell = floor(coordinate);
    float seed = skyHash(cell);
    vec2 point = vec2(skyHash(cell + 31.0), skyHash(cell + 79.0));
    float distance = length(fract(coordinate) - point);
    float radius = clamp(length(fwidth(direction)) * 280.0, 0.11, 0.45);
    float star = (1.0 - smoothstep(radius * 0.2, radius, distance)) * step(0.994, seed);
    // The enlarged lunar sphere also hides stars on its unilluminated side.
    float moonRadius = SKY_MOON_RADIUS * CELESTIAL_SIZE;
    float moonDistance = length(direction - skyMoonDirection());
    float moonEdge = max(length(fwidth(direction)), 0.0002);
    float moonCoverage = 1.0 - smoothstep(moonRadius - moonEdge, moonRadius + moonEdge, moonDistance);
    star *= 1.0 - moonCoverage;
    vec3 tint = mix(vec3(0.7, 0.82, 1.0), vec3(1.0, 0.83, 0.66), skyHash(cell + 53.0));
    return tint * star * night * mix(0.25, 1.2, seed) * (1.0 - rainStrength * 0.85);
}

// Orthographic sphere normals generate the lunar terminator. The 0-degree
// longitude at the centre shows the Earth-facing LRO hemisphere.
vec3 lunarDisc(vec3 ray, vec3 direction) {
    vec3 reference = abs(direction.y) > 0.95 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    vec3 right = normalize(cross(reference, direction));
    vec3 up = normalize(cross(direction, right));
    float radius = SKY_MOON_RADIUS * CELESTIAL_SIZE;
    vec2 position = vec2(dot(ray, right), dot(ray, up)) / radius;
    float squared = dot(position, position);
    if (squared > 1.02 || dot(ray, direction) < 0.0 || direction.y < -radius) {
        return vec3(0.0);
    }
    float z = sqrt(max(1.0 - squared, 0.0));
    vec3 normal = vec3(position, z);
    float angle = float(moonPhase) * PI * 0.25;
    vec3 light = vec3(sin(angle), 0.0, cos(angle));
    float incidence = max(dot(normal, light), 0.0);
    float longitude = atan(normal.x, max(normal.z, 0.0001)) / (2.0 * PI) + 0.5;
    float latitude = 0.5 - asin(clamp(normal.y, -1.0, 1.0)) / PI;
    vec2 atlas = vec2((longitude * 511.0 + 0.5) / 1024.0,
                      (768.0 + latitude * 255.0 + 0.5) / 1024.0);
    vec3 albedo = toLinearSpace(texture2D(noisetex, atlas).rgb);
    float edgeWidth = max(length(fwidth(ray)) / radius, 0.015);
    float edge = 1.0 - smoothstep(1.0 - edgeWidth, 1.0 + edgeWidth, sqrt(squared));
    float earthshine = 0.006 * (1.0 - lunarIlluminatedFraction());
    vec3 transmission = atmosphereDirectTransmittance(direction.y);
    float horizon = smoothstep(-0.006, 0.002, ray.y);
    return albedo * (incidence * 2.8 + earthshine) * transmission * edge * horizon
         * clamp(MOONLIGHT_STRENGTH / 0.018, 0.0, 3.0);
}

vec3 skyCelestialRadiance(vec3 ray) {
    vec3 sun = skySunDirection();
    float radius = SKY_SUN_RADIUS * CELESTIAL_SIZE;
    float distance = length(ray - sun);
    float edgeWidth = max(length(fwidth(ray)), 0.0002);
    float disc = 1.0 - smoothstep(radius - edgeWidth, radius + edgeWidth, distance);
    disc *= smoothstep(-0.006, 0.002, ray.y);
    float limb = sqrt(max(1.0 - distance * distance / (radius * radius), 0.0));
    vec3 solar = vec3(12.0) * disc * mix(0.65, 1.0, limb)
               * atmosphereDirectTransmittance(sun.y) * SUNLIGHT_STRENGTH;
    return solar + lunarDisc(ray, skyMoonDirection());
}

vec3 skyRadiance(vec3 direction) {
    return skyAtmosphereRadiance(direction) + skyStars(direction) + skyCelestialRadiance(direction);
}

#endif
