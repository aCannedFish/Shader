#version 330 core
#include "volume.glsl"
#include "optics.glsl"
uniform ivec2 uTileOrigin;
uniform vec3 uLightPosition;
uniform vec3 uSunDirection;
uniform float uLightRadius;
uniform int uDirectional;
layout(location = 0) out vec4 transmission;

// Padded slices permit two filtered texture reads to reconstruct each RGB volume.
void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy) - uTileOrigin;
    int side = uSize + 2;
    ivec3 cell = ivec3(pixel.x % side - 1, pixel.y % side - 1,
        (pixel.y / side) * 8 + pixel.x / side);
    cell = clamp(cell, ivec3(0), ivec3(uSize - 1));
    vec3 target = vec3(cell) + 0.5;
    vec3 source = uDirectional == 1 ? target + uSunDirection * float(uSize) * 3.0 : uLightPosition;
    if (uDirectional == 0 && length(target - source) > uLightRadius + 1.0) {
        transmission = vec4(1.0);
        return;
    }
    transmission = vec4(traceTransmission(source, target), 1.0);
}
