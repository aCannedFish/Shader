#include "/lib/world/lookup.glsl"
#include "/lib/world/static.glsl"
#include "/lib/world/shapes.glsl"
/* RENDERTARGETS: 1 */
/*
const int colortex1Format = RGBA32F;
*/
uniform sampler2D depthtex0;
uniform sampler2D colortex6;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;
uniform float viewWidth;
uniform float viewHeight;
layout(location=0) out vec4 result;

// This readback probe matches rendered depth to observed model surfaces. Near a
// block boundary, depth quantization can place the reconstructed point in the
// adjacent block. Check both owners only within that narrow coordinate error;
// no ray, edge pixel or failed query is removed from the reported results.
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    float depth = texture(depthtex0, uv).r;
    result = vec4(0.0);
    if (depth >= 1.0) return;
    vec4 view = gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec3 relative = (gbufferModelViewInverse * vec4(view.xyz / view.w, 1.0)).xyz;
    float distance = length(relative);
    if (distance < 0.0001) return;
    vec3 direction = relative / distance;
    WorldPosition surface = worldPosition(relative, cameraPosition);
    ivec3 low = surface.block;
    ivec3 high = surface.block;
    for (int axis = 0; axis < 3; axis++) {
        if (surface.fraction[axis] < 0.003) low[axis]--;
        if (surface.fraction[axis] > 0.997) high[axis]++;
    }
    ivec3 dimensions = high - low + 1;
    int candidates = dimensions.x * dimensions.y * dimensions.z;
    float error = 1e20;
    result = vec4(-1.0, -1.0, distance, 0.0);
    for (int candidate = 0; candidate < 8; candidate++) {
        if (candidate >= candidates) break;
        ivec3 offset = ivec3(candidate % dimensions.x,
            (candidate / dimensions.x) % dimensions.y,
            candidate / (dimensions.x * dimensions.y));
        WorldPosition owner = WorldPosition(low + offset, vec3(0.5));
        WorldSample sample = worldRead(colortex6, owner);
        if (sample.state == WORLD_UNKNOWN) continue;
        ivec3 shape = worldShapeDescriptor(colortex6, sample.material);
        ivec4 region = worldRegion(WORLD_REGION_SHAPES);
        vec3 origin = -worldCameraRelative(WorldPosition(owner.block, vec3(0.0)), cameraPosition);
        WorldShapeHit hit = worldIntersectShape(colortex6, shape.x, shape.y, region.z, region.xy,
            origin, direction, 0.00001, distance + 2.0);
        float mismatch = hit.valid ? abs(hit.distance - distance) : 1e19;
        if (mismatch < error) {
            error = mismatch;
            result = vec4(float(sample.material), hit.valid ? hit.distance : -1.0,
                distance, float(shape.y));
        }
    }
}
