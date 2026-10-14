/*
 * Spherical atmosphere integration in kilometres. Rayleigh, aerosol scattering
 * and ozone absorption share one density model. A small sky-view lookup is
 * rebuilt before transparent geometry; higher scattering orders are approximated
 * by a modest isotropic source. No compute shader or high-dimensional LUT is used.
 */
#ifndef LIB_ATMOSPHERE_GLSL
#define LIB_ATMOSPHERE_GLSL

#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"

const float SKY_PLANET_RADIUS = 6371.0;
const float SKY_ATMOSPHERE_RADIUS = 6451.0;
const vec3 SKY_RAYLEIGH = vec3(0.005802, 0.013558, 0.033100);
const vec3 SKY_OZONE = vec3(0.000650, 0.001881, 0.000085);

vec3 skySunDirection() {
    return safeNormalize(mat3(gbufferModelViewInverse) * sunPosition, vec3(0.0, 1.0, 0.0));
}

vec3 skyMoonDirection() {
    return safeNormalize(mat3(gbufferModelViewInverse) * moonPosition, vec3(0.0, 1.0, 0.0));
}

float skyDaylight() {
    return smoothstep(-0.12, 0.16, skySunDirection().y);
}

float lunarIlluminatedFraction() {
    return 0.5 + 0.5 * cos(float(moonPhase) * PI * 0.25);
}

vec3 atmosphereDensity(float altitude) {
    altitude = max(altitude, 0.0);
    float ozone = max(0.0, 1.0 - abs(altitude - 25.0) / 15.0);
    return vec3(exp(-altitude / 8.0), exp(-altitude / 1.2), ozone);
}

float atmosphereAerosol() {
    return SKY_HAZE * mix(1.0, 3.0, rainStrength);
}

vec3 atmosphereExtinction(vec3 columns) {
    return SKY_RAYLEIGH * columns.x
         + vec3(0.004440 * atmosphereAerosol()) * columns.y
         + SKY_OZONE * columns.z;
}

// Kasten-style optical air mass is inexpensive enough for geometry and discs.
vec3 atmosphereDirectTransmittance(float elevation) {
    float mu = max(elevation, 0.0);
    float zenith = acos(clamp(mu, 0.0, 1.0)) * 180.0 / PI;
    float airMass = 1.0 / (mu + 0.50572 * pow(max(96.07995 - zenith, 0.01), -1.6364));
    return exp(-atmosphereExtinction(vec3(8.0, 1.2, 15.0) * airMass));
}

// Stable roots also allow twilight scattering above the ground shadow.
float atmosphereExitDistance(vec3 origin, vec3 ray, float radius) {
    float b = dot(origin, ray);
    float c = dot(origin, origin) - radius * radius;
    return max(-b + sqrt(max(b * b - c, 0.0)), 0.0);
}

bool atmosphereGroundBlocks(vec3 origin, vec3 ray) {
    float b = dot(origin, ray);
    float c = dot(origin, origin) - SKY_PLANET_RADIUS * SKY_PLANET_RADIUS;
    return b < 0.0 && b * b - c > 0.0;
}

// Six non-uniform samples concentrate work in the dense lower atmosphere.
vec3 atmosphereLightTransmission(vec3 origin, vec3 lightDirection) {
    if (atmosphereGroundBlocks(origin, lightDirection)) {
        return vec3(0.0);
    }
    float distance = atmosphereExitDistance(origin, lightDirection, SKY_ATMOSPHERE_RADIUS);
    vec3 columns = vec3(0.0);
    float previous = 0.0;
    for (int stepIndex = 0; stepIndex < 6; stepIndex++) {
        float u = float(stepIndex + 1) / 6.0;
        float next = u * u * distance;
        vec3 position = origin + lightDirection * (previous + next) * 0.5;
        columns += atmosphereDensity(length(position) - SKY_PLANET_RADIUS) * (next - previous);
        previous = next;
    }
    return exp(-atmosphereExtinction(columns));
}

float atmosphereMiePhase(float cosine) {
    const float g = 0.76;
    return (1.0 - g * g) / (4.0 * PI * pow(max(1.0 + g * g - 2.0 * g * cosine, 0.01), 1.5));
}

// This is evaluated only in the small sky-view pass, not per scene pixel.
vec3 integrateAtmosphere(vec3 direction) {
    vec3 ray = direction;
    if (ray.y < 0.003) {
        // 下半球使用地平线延续；先归一化水平方向，不能把接近零的
        // xz 与固定 y 相除，否则正下方会突然变成天顶方向。
        vec2 horizontal = length(ray.xz) > 0.00001
            ? normalize(ray.xz) : vec2(1.0, 0.0);
        ray = vec3(horizontal.x, 0.003, horizontal.y);
    }
    ray = normalize(ray);
    float altitude = clamp(cameraPosition.y * 0.001, 0.05, 4.0);
    vec3 origin = vec3(0.0, SKY_PLANET_RADIUS + altitude, 0.0);
    float distance = atmosphereExitDistance(origin, ray, SKY_ATMOSPHERE_RADIUS);
    vec3 sun = skySunDirection();
    vec3 moon = skyMoonDirection();
    float sunCosine = dot(ray, sun);
    float moonCosine = dot(ray, moon);
    float sunRayleighPhase = 3.0 * (1.0 + sunCosine * sunCosine) / (16.0 * PI);
    float moonRayleighPhase = 3.0 * (1.0 + moonCosine * moonCosine) / (16.0 * PI);
    float sunMiePhase = atmosphereMiePhase(sunCosine);
    float moonMiePhase = atmosphereMiePhase(moonCosine);
    float moonEnergy = MOONLIGHT_STRENGTH * (0.08 + 0.92 * lunarIlluminatedFraction()) * 0.25;
    vec3 transmittance = vec3(1.0);
    vec3 radiance = vec3(0.0);
    float previous = 0.0;
    for (int stepIndex = 0; stepIndex < SKY_SAMPLES; stepIndex++) {
        float u = float(stepIndex + 1) / float(SKY_SAMPLES);
        float next = u * u * distance;
        float stepLength = next - previous;
        vec3 position = origin + ray * (previous + next) * 0.5;
        vec3 density = atmosphereDensity(length(position) - SKY_PLANET_RADIUS);
        vec3 extinction = atmosphereExtinction(density);
        vec3 rayleigh = SKY_RAYLEIGH * density.x;
        vec3 mie = vec3(0.003996 * atmosphereAerosol() * density.y);
        vec3 sunlight = atmosphereLightTransmission(position, sun);
        vec3 moonlight = atmosphereLightTransmission(position, moon);
        vec3 source = (rayleigh * (sunRayleighPhase + 0.018) + mie * sunMiePhase) * sunlight;
        source += (rayleigh * (moonRayleighPhase + 0.012) + mie * moonMiePhase)
                * moonlight * moonEnergy;
        vec3 segmentTransmission = exp(-extinction * stepLength);
        radiance += transmittance * source * (1.0 - segmentTransmission) / max(extinction, vec3(0.000001));
        transmittance *= segmentTransmission;
        previous = next;
    }
    radiance *= 18.0 * SKY_EXPOSURE;
    // 弱夜间散射基底与地表天空环境光共用强度，远处雾保持同一冷色背景。
    radiance += vec3(0.03, 0.06, 0.12) * NIGHT_AMBIENT_STRENGTH * (1.0 - skyDaylight());
    // The lower hemisphere is the horizon continuation, not a second ground mesh.
    return radiance * mix(0.75, 1.0, smoothstep(-0.5, 0.0, direction.y));
}

#endif
