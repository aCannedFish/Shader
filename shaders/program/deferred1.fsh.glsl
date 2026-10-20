/* Supply the sky before translucent blending, and preserve opaque HDR for water. */
/* RENDERTARGETS: 6,0 */
#define MATERIAL_REFLECTION_MIPS
uniform sampler2D colortex1;
#include "../lib/sky_background.glsl"
#include "../lib/material_reflection.glsl"
#include "../lib/clouds.glsl"
uniform sampler2D colortex0;
uniform sampler2D colortex2;
uniform sampler2D depthtex0;
#if ENABLE_MATERIAL_REFLECTIONS == 1
const bool colortex0MipmapEnabled = true;
#endif

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    float depth = texture2D(depthtex0, uv).r;
    vec3 color = fillSkyBackground(texture2D(colortex0, uv).rgb, uv, depth);
#if ENABLE_MATERIAL_REFLECTIONS == 1
    vec2 materialData = unpackMaterial(texture2D(colortex2, uv).a);
    if (depth < 0.999999 && materialData.x > 0.5 && MATERIAL_REFLECTION_STRENGTH > 0.0) {
        vec4 geometry = texture2D(colortex1, uv);
        vec3 normal = decodeNormal(geometry.rg);
        vec3 position = screenToView(uv, depth);
        vec3 incident = normalize(position);
        vec3 direction = normalize(reflect(incident, normal));
        vec3 world = normalize(mat3(gbufferModelViewInverse) * direction);
        SurfaceMaterial m = surfaceMaterial(materialData.x, materialData.y);
        vec4 reflected = traceMaterialScene(colortex0, depthtex0, position + normal * 0.08, direction, m.roughness);
        vec2 lm = texture2D(colortex2, uv).rg;
        vec3 baseEnvironment = materialAmbientEnvironment(world, lm);
        vec3 environment = baseEnvironment;
#if SIMPLE_DIMENSION == 0
        float visibility = smoothstep(0.02, 0.95, lightmapLevel(geometry.b));
        vec4 cloud = cloudEnvironment(world);
        vec3 sky = cloud.rgb + skyAtmosphereRadiance(world) * (1.0 - cloud.a);
        environment = sky * visibility + blockLightRadiance(lm);
#endif
        vec3 fresnel = materialEnvironmentWeight(m, dot(normal, -incident));
        // Replace the forward environment instead of adding a second lobe.
        // Other reflective surfaces already carry a valid low-frequency radiance.
        vec3 specular = (mix(environment, reflected.rgb, reflected.a) - baseEnvironment) * fresnel;
        color = max(color + specular * MATERIAL_REFLECTION_STRENGTH * (1.0 - getFogFactor(length(position))), vec3(0.0));
    }
#endif
    // Glass writes depth. Filling its background afterwards would leave black
    // behind every nonzero-alpha texel, even though clear glass holes look fine.
    gl_FragData[1] = vec4(color, 1.0);
    vec3 opaque = depth < 0.999999
        ? correctSkyFog(color, uv, length(screenToView(uv, depth))) : color;
    gl_FragData[0] = vec4(opaque, 1.0);
}
