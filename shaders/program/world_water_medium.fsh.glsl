/* Camera-column immersion comes from submitted native fluid planes. Closed
 * opaque ceilings cap the optical path and have no exposed surface skylight.
 */
/* RENDERTARGETS: 6 */
#include "/lib/world/environment.glsl"
layout(location=0) out vec4 result;

void main() {
    result = vec4(0.0, 0.0, 0.0, 1573.0);
    if (isEyeInWater != 1) return;
    WorldPosition eye = worldPosition(vec3(0.0), cameraPosition);
    ivec3 origin = worldReadOrigin(colortex6, false);
    ivec2 column = eye.block.xz - origin.xz;
    if (any(lessThan(column, ivec2(0))) || any(greaterThanEqual(column, WORLD_FAR_SHAPE.xz))) return;
    vec4 plane = worldWaterColumn(column, 0);
    vec4 detail = worldWaterColumn(column, 1);
    float height = plane.x + plane.y / 2047.0 + dot(detail.xy, eye.fraction.xz - 0.5);
    bool valid = plane.w > 0.5 && detail.z > 0.5
        && height > cameraPosition.y && height - cameraPosition.y <= 64.0;
    float limit = valid ? height - cameraPosition.y : 64.0;
    vec4 ceiling = worldGroundColumn(column, 1);
    float ceilingDistance = ceiling.r - cameraPosition.y;
    if (ceiling.a > 0.5 && ceilingDistance > 0.0 && ceilingDistance <= limit) {
        result = vec4(ceilingDistance, floor(ceiling.g / 16.0) / 15.0, 3.0, 1573.0);
        return;
    }
    for (int step = 1; step <= 64; step++) {
        float distance = float(eye.block.y + step) - cameraPosition.y;
        if (distance > limit) break;
        WorldSample sample = worldReadCell(colortex6,
            WorldPosition(eye.block + ivec3(0, step, 0), eye.fraction), false);
        if (sample.state != WORLD_SURFACE) continue;
        WorldDefinition definition = worldReadDefinition(colortex6, sample.material);
        if ((definition.flags & 256) != 0 && (definition.flags & 1) == 0) {
            result = vec4(max(distance, 0.0), 0.0, 3.0, 1573.0);
            return;
        }
    }
    if (valid) result = vec4(limit, clamp((detail.z - 1.0) / 15.0, 0.0, 1.0), detail.w, 1573.0);
}
