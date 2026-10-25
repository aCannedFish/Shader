/* Sample reflection radiance before fog and translucent optics. Only this pass
 * advances the history bank; the later water compose reads the current bank.
 */
/* RENDERTARGETS: 7 */
#define WORLD_REFLECTION_CACHE_WRITE
#include "/lib/water_reflection.glsl"
#include "/lib/world/reflection_distribution.glsl"
layout(location=0) out vec4 result;

WorldReflectionHistory previousReflection(vec3 position, vec3 normalWorld) {
    WorldReflectionHistory invalid = worldEmptyReflection();
    vec3 movement = cameraPosition - previousCameraPosition;
    if (any(greaterThan(abs(movement), vec3(32.0)))) return invalid;
    vec3 previousWorld = viewToWorld(position) + movement;
    vec3 previousView = (gbufferPreviousModelView * vec4(previousWorld, 1.0)).xyz;
    vec4 projected = gbufferPreviousProjection * vec4(previousView, 1.0);
    if (projected.w <= 0.0) return invalid;
    vec2 uv = projected.xy / projected.w * 0.5 + 0.5;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) return invalid;
    ivec2 size = textureSize(colortex7, 0);
    ivec2 pixel = ivec2(uv * vec2(size));
    WorldReflectionHistory value = worldReflectionHistoryAt(pixel);
    if (!value.valid || (frameCounter - value.frame + 720720) % 720720 != 1) return invalid;
    // Compare the same water plane, not depths at two different pixel centres.
    // Even half a pixel changes grazing water depth substantially. The previous
    // perspective coefficients reconstruct its ray without a matrix inversion.
    vec2 pixelUv = (vec2(pixel) + 0.5) / vec2(size);
    vec3 previousRay = vec3(
        (pixelUv.x * 2.0 - 1.0 + gbufferPreviousProjection[2][0]) / gbufferPreviousProjection[0][0],
        (pixelUv.y * 2.0 - 1.0 + gbufferPreviousProjection[2][1]) / gbufferPreviousProjection[1][1], -1.0);
    vec3 plane = normalize(mat3(gbufferPreviousModelView) * vec3(0.0, 1.0, 0.0));
    float planeError = abs(dot(plane, previousRay * value.depth - previousView));
    if (planeError > 0.10 || dot(value.normal, normalWorld) < 0.985) return invalid;
    return value;
}

void main() {
    result = vec4(0.0);
    if (isEyeInWater != 0) return;
    ivec2 size = textureSize(colortex7, 0);
    vec2 uv = gl_FragCoord.xy / vec2(size);
    vec4 surface = readWaterSurface(colortex5, colortex1, uv);
    if (surface.a <= 0.001) return;
    vec3 position = waterSurfacePosition(uv, surface.a);
    vec2 bedUv = reflectionPixelUv(uv);
    float bedDepth = texture2D(depthtex1, bedUv).r;
    if (bedDepth < 0.999999 && length(screenToView(bedUv, bedDepth) - position) < 1.0) {
        // Contact pixels are traced at display resolution by the optics pass;
        // do not also pay for a reduced-resolution result that it will discard.
        return;
    }
    vec3 normal = decodeWaterNormal(surface.xy);
    vec3 incident = normalize(position);
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
    vec3 up = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0);
    float roughness = WATER_ROUGHNESS;
    vec3 sum = vec3(0.0);
    float total = 0.0;
    float confidence = 0.0;
    for (int index = 0; index < WORLD_REFLECTION_DIRECTIONS; index++) {
#if WORLD_REFLECTION_DIRECTIONS == 1
        // One direction uses the centre of the lobe. Stochastic wide-angle
        // sampling without enough samples produces visible snow at low FPS;
        // source-plane reconstruction supplies this tier's small footprint.
        vec3 direction = normalize(reflect(incident, normal));
#else
        vec3 direction = worldReflectionDirection(incident, normal, roughness,
            worldReflectionSequence(ivec2(gl_FragCoord.xy), index));
#endif
        if (dot(direction, up) <= 0.0 || dot(normal, -incident) <= 0.0) continue;
        // Visible-normal sampling cancels D and the view masking term. The
        // remaining Smith ratio weights the incident radiance; normalize the
        // samples so this filter does not darken coloured reflections.
        float cosine = max(dot(normal, direction), 0.001);
        float alpha2 = pow4(roughness);
        float smith = 2.0 * cosine / (cosine + sqrt(alpha2 + (1.0 - alpha2) * cosine * cosine));
        vec4 value = queryWaterRadiance(position, direction, roughness, surface.b);
        sum += value.rgb * smith;
        confidence += value.a * smith;
        total += smith;
    }
    if (total <= 0.0) return;
    vec3 current = sum / total;
    WorldReflectionHistory value = WorldReflectionHistory(current, normalWorld,
        surface.a, confidence / total, frameCounter, 1, true);
    WorldReflectionHistory history = previousReflection(position, normalWorld);
    if (history.valid) {
        float magnitude = max(max(current.r, current.g), current.b);
        float difference = max(max(abs(current.r - history.radiance.r),
            abs(current.g - history.radiance.g)), abs(current.b - history.radiance.b));
        // Large lighting or geometry changes reject the old radiance rather
        // than fading stale bright/dark patches into the new reflection.
        if (difference <= 0.04 + magnitude * 0.45) {
            value.count = min(history.count + 1, WORLD_REFLECTION_HISTORY);
            float blend = 1.0 / float(value.count);
            blend = max(blend, 0.2 * (1.0 - history.confidence));
            value.radiance = mix(history.radiance, current, blend);
        }
    }
    result = worldPackReflection(value);
}
