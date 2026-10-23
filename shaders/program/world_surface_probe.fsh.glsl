#include "/lib/world/lookup.glsl"
#include "/lib/world/static.glsl"
#include "/lib/world/shapes.glsl"
#include "/lib/world/surface_uv.glsl"
#include "/lib/world/model_query.glsl"
#include "/lib/world/glass_query.glsl"
/* RENDERTARGETS: 1,3,4,5 */
/*
const int colortex3Format = RGBA32F;
const int colortex4Format = RGBA32F;
*/
#ifdef WORLD_UV_PROBE
uniform sampler2D colortex2;
uniform sampler2D noisetex;
uniform sampler2D depthtex2;
#endif
layout(location=1) out vec4 uvResult;
layout(location=2) out vec4 uvReference;
layout(location=3) out vec4 surfaceColour;
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
    uvResult = vec4(0.0);
    uvReference = vec4(0.0);
    surfaceColour = vec4(0.0);
#ifdef WORLD_UV_PROBE
    // Snapshot before later glass/water passes overwrite the live raster UVs.
    uvReference = texelFetch(colortex2, ivec2(gl_FragCoord.xy), 0);
    uvResult = vec4(-1.0, -1.0, uvReference.xy);
#endif
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
        if (surface.fraction[axis] < 0.501) low[axis]--;
        if (surface.fraction[axis] > 0.499) high[axis]++;
    }
    ivec3 dimensions = high - low + 1;
    int candidates = dimensions.x * dimensions.y * dimensions.z;
    float error = 1e20;
    result = vec4(-1.0, -1.0, distance, 0.0);
    surfaceColour = vec4(1.0, 0.0, 1.0, 1.0);
    for (int candidate = 0; candidate < 27; candidate++) {
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
        WorldShapeHit hit;
#ifdef WORLD_MODEL_UV
        WorldAttributes attributes = worldReadAttributes(colortex6, noisetex, owner, sample.material);
        WorldSurfaceHit surfaceHit = worldIntersectModel(colortex6, noisetex, depthtex2, sample.material, attributes,
            origin, direction, 0.00001, distance + 2.0, true, 0.1);
        hit = WorldShapeHit(surfaceHit.status == WORLD_HIT, surfaceHit.distance, surfaceHit.normal, surfaceHit.quad);
#else
        hit = worldIntersectShape(colortex6, shape.x, shape.y, region.z, WORLD_SHAPE_STRIDE, region.xy,
            origin, direction, 0.00001, distance + 2.0);
#endif
        float mismatch = hit.valid ? abs(hit.distance - distance) : 1e19;
        if (mismatch < error) {
            error = mismatch;
            result = vec4(float(sample.material), hit.valid ? hit.distance : -1.0,
                distance, float(shape.y));
#ifdef WORLD_UV_PROBE
            uvResult.xy = vec2(-1.0);
            if (hit.valid) {
                int axis = worldSurfaceAxis(hit.normal);
                int face = axis * 2 + int(hit.normal[axis] < 0.0);
                WorldUv mapping = worldReadNearUv(colortex6, owner, face);
                vec3 local = origin + direction * hit.distance;
#ifdef WORLD_MODEL_UV
                mapping = worldReadModelFaceUv(colortex6, noisetex, hit.box, attributes);
                WorldSurfaceMaterial surfaceMaterial = worldSampleModelLayers(colortex6, noisetex,
                    depthtex2, sample.material, local, hit.normal, attributes);
                surfaceColour.rgb = surfaceMaterial.valid ? surfaceMaterial.albedo : vec3(1.0, 0.0, 1.0);
                if (surfaceMaterial.alphaType == 2) {
                    bool glassValid;
                    vec3 transmission = worldQueryGlassTransmission(colortex6, sample.material, attributes,
                        origin, direction, 0.00001, distance + 2.0, glassValid);
                    surfaceColour.rgb = glassValid ? transmission : vec3(1.0, 0.0, 1.0);
                }

#endif
                if (mapping.valid) uvResult.xy = worldSurfaceUv(mapping, worldSurfaceProjection(local, axis));
            }
#endif
        }
    }
}
