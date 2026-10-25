/* Material reflection validates a true ray/surface correspondence. A wide
 * adaptive candidate is a search hint, not permission to duplicate a bright
 * torch elsewhere on a wall. World geometry fills hidden/failed screen hits.
 */
#ifndef SIMPLE_WORLD_REFLECTION_MATERIAL_GLSL
#define SIMPLE_WORLD_REFLECTION_MATERIAL_GLSL
#include "/lib/world/reflection_occlusion.glsl"
#include "/lib/materials.glsl"

// Only emitters represented by an active analytical specular light are split
// out of the geometry contribution. Unselected lights retain their real image.
float worldMaterialEmitterEnergy(vec3 point, vec3 origin, vec3 direction,
    float roughness, float analyticalCoverage) {
    float analytical = materialAnalyticEmitterWeight(roughness) * analyticalCoverage;
    if (analytical <= 0.0 || !hasCompanionLighting()) return 1.0;
    WorldPosition source = worldPosition(viewToWorld(point + direction * 0.003), cameraPosition);
    WorldSample sample = worldReadCell(colortex6, source, false);
    if (sample.state < WORLD_SURFACE
        || worldReadDefinition(colortex6, sample.material).emissionLevel <= 0) return 1.0;
    if (worldStaticTexel(noisetex, 140000 + sample.material).b < 0.5) return 1.0;
    for (int slot = 0; slot < WORLD_POINT_LIGHT_COUNT; slot++) {
        if (slot >= LOCAL_LIGHT_COUNT) break;
        WorldPointLight light = worldReadPointLight(colortex6, slot);
        if (light.valid && all(equal(light.position.block, source.block))
            && worldShadowLightMapped(colortex6, slot, false)) {
            WorldPosition receiver = worldPosition(viewToWorld(origin), cameraPosition);
            vec3 ray = vec3(light.position.block - receiver.block)
                + light.position.fraction - receiver.fraction;
            float squared = dot(ray, ray);
            vec3 normal = normalize(mat3(gbufferModelViewInverse)
                * normalize(-normalize(origin) + direction));
            if (squared >= light.radius * light.radius || squared <= 0.0001
                || dot(normal, ray) <= 0.0) return 1.0;
            return 1.0 - analytical;
        }
    }
    return 1.0;
}

vec4 worldMaterialScreenHit(sampler2D scene, sampler2D depths, vec3 origin, vec3 direction) {
    ScreenReflectionHit candidate = traceAdaptiveReflectionDetailed(scene, depths,
        origin, direction, 0.001, far, MATERIAL_REFLECTION_STEPS, vec4(0.0));
    if (candidate.coverage <= 0.0) return vec4(0.0);
    vec2 uv = candidate.uv;
    float distance;
    int kind;
    if (reflectionSurfaceHit(depths, origin, direction, 0.001, far, uv, distance, kind)) {
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) return vec4(0.0);
        return vec4(uv, distance, 1.0);
    }
    if (kind != 1) return vec4(0.0);
    // Isolated cutout texels have no plane. Their actual pixel cone still
    // bounds correspondence; a coarse metre-wide segment cannot validate them.
    vec3 point = screenToView(candidate.uv, reflectionSourceRead(depths, candidate.uv).r);
    float along = dot(point - origin, direction);
    float perpendicular = length(point - origin - direction * along);
    float footprint = max(0.001, -point.z * abs(gbufferProjectionInverse[1][1])
        / max(viewHeight, 1.0));
    return along > 0.001 && perpendicular < footprint * 1.2
        ? vec4(candidate.uv, along, 1.0) : vec4(0.0);
}

vec4 worldMaterialReflection(sampler2D scene, sampler2D depths, vec3 origin,
    vec3 direction, float roughness, float analyticalCoverage, out float distance) {
    vec4 screen = worldMaterialScreenHit(scene, depths, origin, direction);
    float maximum = screen.a > 0.0 ? screen.z + max(0.05, screen.z * 0.01) : far;
    float worldDistance;
    vec4 world = reflectionOcclusionPlaneRaw(scene, depths, origin, direction, vec3(0.0),
        vec4(0.0), maximum, worldDistance);
    if (world.a > 0.0 && (screen.a <= 0.0
        || worldDistance <= screen.z + max(0.015, worldDistance * 0.001))) {
        distance = worldDistance;
        world.rgb *= worldMaterialEmitterEnergy(origin + direction * distance,
            origin, direction, roughness, analyticalCoverage);
        world.rgb = reflectionAirMedium(world.rgb, distance, direction);
        return world;
    }
    if (screen.a > 0.0) {
        distance = screen.z;
        float depth = reflectionSceneDepth(depths, screen.xy);
        vec4 filtered = reflectionSourceFiltered(scene, depths, screen.xy, depth, distance, roughness);
        vec3 point = screenToView(screen.xy, reflectionSourceRead(depths, screen.xy).r);
        filtered.rgb *= worldMaterialEmitterEnergy(point, origin, direction, roughness, analyticalCoverage);
        return vec4(reflectionAirMedium(filtered.rgb, distance, direction), 1.0);
    }
    distance = 0.0;
    return vec4(0.0);
}
#endif
