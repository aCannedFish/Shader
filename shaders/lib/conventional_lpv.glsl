/* Optional compact colored-light volume. C8 owns a persistent RGB field;
 * C1 is used as voxel scratch only between shadow and prepare. Scene geometry
 * receives the native light energy tinted by this bounded propagation field.
 */
#ifndef SIMPLE_CONVENTIONAL_LPV_GLSL
#define SIMPLE_CONVENTIONAL_LPV_GLSL
#include "/settings.glsl"
#include "/lib/uniforms.glsl"

#if ENABLE_COLOURED_LIGHTING == 1
uniform sampler2D colortex8;

ivec3 lpvShape() {
    int side = COLOURED_VOLUME_SIZE;
    int capacity = int(viewWidth) * int(viewHeight);
    for (int scale = 0; scale < 3; scale++) {
        if (side * side * (side / 2) <= capacity) break;
        side /= 2;
    }
    return ivec3(side, side / 2, side);
}

ivec3 lpvOrigin(vec3 camera) {
    return ivec3(floor(camera)) - lpvShape() / 2;
}

bool lpvInside(ivec3 cell) {
    return all(greaterThanEqual(cell, ivec3(0))) && all(lessThan(cell, lpvShape()));
}

int lpvIndex(ivec3 cell) {
    ivec3 shape = lpvShape();
    return cell.x + shape.x * (cell.y + shape.y * cell.z);
}

ivec2 lpvAddress(ivec3 cell) {
    int address = lpvIndex(cell) + 1;
    int width = textureSize(colortex8, 0).x;
    return ivec2(address % width, address / width);
}

int lpvHeaderFrame(vec4 header) {
    return int(round(header.y)) + int(round(header.z)) * 1024;
}

bool lpvHeaderValid(vec4 header) {
    int delta = (frameCounter - lpvHeaderFrame(header) + 720720) % 720720;
    return header.w == 1957.0 && int(round(header.x)) == lpvShape().x && delta <= 1;
}

vec3 lpvReadCell(ivec3 cell) {
    if (!lpvInside(cell)) return vec3(0.0);
    return max(texelFetch(colortex8, lpvAddress(cell), 0).rgb, vec3(0.0));
}

vec3 lpvSample(vec3 world) {
    if (!lpvHeaderValid(texelFetch(colortex8, ivec2(0), 0))) return vec3(0.0);
    vec3 position = world - vec3(lpvOrigin(cameraPosition)) - 0.5;
    ivec3 first = ivec3(floor(position));
    vec3 weight = fract(position);
    vec3 result = vec3(0.0);
    for (int corner = 0; corner < 8; corner++) {
        ivec3 offset = ivec3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        vec3 blend = mix(1.0 - weight, weight, vec3(offset));
        result += lpvReadCell(first + offset) * blend.x * blend.y * blend.z;
    }
    return result;
}

vec3 lpvBlockLight(vec3 viewPosition, vec3 normalView, vec3 nativeRadiance) {
    if (nativeRadiance.r <= 0.000001) return nativeRadiance;
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 world = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz + cameraPosition;
    vec3 light = lpvSample(world + normal * 0.7);
    float peak = max(light.r, max(light.g, light.b));
    float coverage = smoothstep(0.0001, 0.003, peak) * COLOURED_LIGHT_INTENSITY;
    vec3 hue = sqrt(max(light / max(peak, 0.000001), vec3(0.0)));
    return mix(nativeRadiance, nativeRadiance.r * hue, coverage);
}
#endif
#endif
