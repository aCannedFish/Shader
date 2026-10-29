/* Sky lookup, circular celestial bodies and a continuous stellar background. */
#ifndef LIB_SKY_GLSL
#define LIB_SKY_GLSL

#include "atmosphere.glsl"
#include "color_space.glsl"

uniform sampler2D colortex3;
#include "sky_noise.glsl"

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
    float azimuth = dot(direction.xz, direction.xz) > 0.00000001
        ? atan(direction.z, direction.x) / (2.0 * PI) + 0.5 : 0.5;
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

// Packed sky/cloud strips are periodic in azimuth, but the whole attachment
// cannot use GL_REPEAT: its other half stores cloud shadows. Only seam pixels
// need two explicit reads; interior pixels keep one hardware-filtered lookup.
vec4 sampleSkyStrip(vec2 coordinate, float strip) {
    vec2 size = max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0));
    float x = coordinate.x * size.x - 0.5;
    float y = clamp(coordinate.y, 0.0, 1.0) * (size.y - 1.0) + 0.5 + strip * size.y;
    if (x >= 0.0 && x <= size.x - 1.0) {
        return texture2D(colortex3, vec2(x + 0.5, y) / vec2(viewWidth, viewHeight));
    }
    // 经度只跨过一次边界。显式环绕列号，避免浮点mod在245等宽度上
    // 将mod(width, width)舍入成width，读到天空条带右侧的黑色缓存。
    float lower = floor(x);
    if (lower < 0.0) {
        lower += size.x;
    }
    float upper = lower + 1.0;
    if (upper >= size.x) {
        upper = 0.0;
    }
    vec4 a = texture2D(colortex3, vec2(lower + 0.5, y) / vec2(viewWidth, viewHeight));
    vec4 b = texture2D(colortex3, vec2(upper + 0.5, y) / vec2(viewWidth, viewHeight));
    return mix(a, b, fract(x));
}

vec3 skyAtmosphereRadiance(vec3 direction) {
    return sampleSkyStrip(skyLookupCoordinate(direction), 0.0).rgb;
}

// Sky queries run behind depth and water branches, where screen derivatives are
// undefined at silhouettes. Derive a finite pixel cone from projection instead.
float skyPixelAngularWidth(vec3 direction) {
    vec2 planeStep = 2.0 * abs(vec2(gbufferProjectionInverse[0][0],
                                  gbufferProjectionInverse[1][1]))
                   / max(vec2(viewWidth, viewHeight), vec2(1.0));
    vec3 viewRay = normalize(mat3(gbufferModelView) * direction);
    vec2 angularStep = planeStep * abs(viewRay.z)
                     * sqrt(max(vec2(1.0) - viewRay.xy * viewRay.xy, vec2(0.0)));
    return max(length(angularStep), 0.0002);
}

float skyHash(vec2 p) {
    vec3 value = fract(vec3(p.x, p.y, p.x) * 0.1031);
    value += dot(value, value.yzx + 33.33);
    return fract((value.x + value.y) * value.z);
}

// The End's stars resolve at final scene resolution rather than being baked
// into the tiny nebula LUT. A compact 3D kernel has no longitude or pole seam.
vec3 endStellarRadiance(vec3 direction) {
#if SIMPLE_DIMENSION != 1
    return vec3(0.0);
#else
    if (END_ATMOSPHERE <= 0.0) {
        return vec3(0.0);
    }
    vec3 p = direction * 256.0;
    vec3 cell = floor(p);
    float seed = atmosphereHash(cell);
    float radius = clamp(skyPixelAngularWidth(direction) * 256.0 * 0.8, 0.12, 0.45);
    float star = (1.0 - smoothstep(radius * 0.15, radius, length(fract(p) - 0.5))) * step(0.997, seed);
    vec3 tint = mix(vec3(0.55, 0.72, 1.0), vec3(1.0, 0.72, 0.58), atmosphereHash(cell + 19.0));
    return tint * star * (0.20 + 0.60 * atmosphereHash(cell + 47.0)) * END_ATMOSPHERE;
#endif
}

// Stars use spherical cells. Angular derivatives are taken from the ray itself,
// so the longitude seam cannot create a bright vertical line.
vec3 skyStars(vec3 direction) {
#if SIMPLE_DIMENSION == 1
    return endStellarRadiance(direction);
#elif SIMPLE_DIMENSION == -1
    return vec3(0.0);
#endif
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
    float angularWidth = skyPixelAngularWidth(direction);
    float radius = clamp(angularWidth * 280.0, 0.11, 0.45);
    float star = (1.0 - smoothstep(radius * 0.2, radius, distance)) * step(0.994, seed);
    // The enlarged lunar sphere also hides stars on its unilluminated side.
    float moonRadius = SKY_MOON_RADIUS * CELESTIAL_SIZE;
    float moonDistance = length(direction - skyMoonDirection());
    float moonEdge = min(angularWidth, moonRadius * 0.10);
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
    float edgeWidth = clamp(skyPixelAngularWidth(ray) / radius, 0.015, 0.10);
    float edge = 1.0 - smoothstep(1.0 - edgeWidth, 1.0 + edgeWidth, sqrt(squared));
    float earthshine = 0.006 * (1.0 - lunarIlluminatedFraction());
    vec3 transmission = atmosphereDirectTransmittance(direction.y);
    float horizon = smoothstep(-0.006, 0.002, ray.y);
    return albedo * (incidence * 2.8 + earthshine) * transmission * edge * horizon
         * clamp(MOONLIGHT_STRENGTH / 0.018, 0.0, 3.0);
}

vec3 skyCelestialRadiance(vec3 ray) {
#if SIMPLE_DIMENSION != 0
    return vec3(0.0);
#endif
    vec3 sun = skySunDirection();
    float radius = SKY_SUN_RADIUS * CELESTIAL_SIZE;
    float distance = length(ray - sun);
    float edgeWidth = min(skyPixelAngularWidth(ray), radius * 0.10);
    float disc = 1.0 - smoothstep(radius - edgeWidth, radius + edgeWidth, distance);
    disc *= smoothstep(-0.006, 0.002, ray.y);
    float limb = sqrt(max(1.0 - distance * distance / (radius * radius), 0.0));
    vec3 solar = vec3(12.0) * disc * mix(0.65, 1.0, limb)
               * atmosphereDirectTransmittance(sun.y) * SUNLIGHT_STRENGTH;
    return solar * mix(1.0, 0.12, weatherRainAmount())
         + lunarDisc(ray, skyMoonDirection()) * mix(1.0, 0.35, weatherRainAmount());
}

vec3 skyRadiance(vec3 direction) {
    return skyAtmosphereRadiance(direction) + skyStars(direction) + skyCelestialRadiance(direction);
}

#endif
