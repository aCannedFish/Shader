/* Supply the sky before translucent blending, and preserve opaque HDR for water. */
/* RENDERTARGETS: 6,0,1,2 */
#define MATERIAL_REFLECTION_MIPS
uniform sampler2D colortex1;
#include "../lib/sky_background.glsl"
#include "../lib/material_reflection.glsl"
#include "../lib/clouds.glsl"
#include "../lib/wet_surface.glsl"
#include "../lib/reflection_occlusion.glsl"
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
    vec2 materialData = unpackMaterial(texture2D(colortex2, uv).a);
    bool materialReflection = false;
#if ENABLE_MATERIAL_REFLECTIONS == 1
    materialReflection = materialData.x > 0.5 && MATERIAL_REFLECTION_STRENGTH > 0.0;
#endif
    bool wetActive = weatherGroundWetness() * RAIN_PUDDLES_STRENGTH > 0.001;
    vec3 relative = vec3(0.0);
    float footprint = 0.0;
    // 湿度是整帧常量，晴天跳过地表重建；雨天在几何分支前取得连续导数。
    if (wetActive) {
        relative = viewToWorld(screenToView(uv, depth));
        footprint = max(length(dFdx(relative.xz)), length(dFdy(relative.xz)));
    }
    vec3 position = vec3(0.0);
    vec4 geometry = vec4(0.0);
    vec3 normal = vec3(0.0, 1.0, 0.0);
    vec2 wet = vec2(0.0);
    if (depth < 0.999999 && (materialReflection || wetActive)) {
        geometry = texture2D(colortex1, uv);
        normal = decodeNormal(geometry.rg);
        position = screenToView(uv, depth);
        if (wetActive && abs(geometry.a - MAT_WET_GROUND) < 0.025) {
            vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
            wet = wetGroundCoverage(relative, normalWorld, geometry.b, materialData.x, footprint);
            color *= 1.0 - wet.x * 0.12 - wet.y * 0.18;
        }
    }
#if ENABLE_MATERIAL_REFLECTIONS == 1
    if (depth < 0.999999 && (materialReflection || wet.y > 0.015)) {
        vec3 incident = normalize(position);
        vec2 lm = texture2D(colortex2, uv).rg;
        SurfaceMaterial m = surfaceMaterial(materialData.x, materialData.y);
        vec3 originalFresnel = materialReflection
            ? materialEnvironmentWeight(m, dot(normal, -incident)) * MATERIAL_REFLECTION_STRENGTH
            : vec3(0.0);
        vec3 originalDirection = normalize(mat3(gbufferModelViewInverse) * reflect(incident, normal));
        vec3 baseEnvironment = materialAmbientEnvironment(originalDirection, lm) * originalFresnel;
        normal = wetSurfaceNormal(normal, relative, wet.y, footprint);
        SurfaceMaterial coatingMaterial;
        coatingMaterial.f0 = vec3(0.025);
        coatingMaterial.roughness = 0.20;
        coatingMaterial.metallic = 0.0;
        vec3 coating = materialEnvironmentWeight(coatingMaterial, dot(normal, -incident));
        vec3 fresnel = mix(originalFresnel, coating, wet.y);
        m.roughness = mix(m.roughness, 0.20, wet.y);
        vec3 direction = normalize(reflect(incident, normal));
        vec3 world = normalize(mat3(gbufferModelViewInverse) * direction);
        float reflectedDistance;
        vec4 reflected = traceMaterialScene(colortex0, depthtex0, position + normal * 0.08, direction,
                                            m.roughness, reflectedDistance);
        // 阴影贴图找出树冠、屋檐等相机看不到的遮挡，代替天空或穿过遮挡物后的远处命中。
        float occlusionDistance;
        vec4 occlusion = reflectionOcclusion(colortex0, depthtex0, position, direction,
                                             reflectionHiddenAmbient(world, lm), occlusionDistance);
        if (reflectionOcclusionCloser(occlusion, occlusionDistance, reflectedDistance)) {
            reflected.a = 0.0;
        }
        vec3 environment = materialAmbientEnvironment(world, lm);
#if SIMPLE_DIMENSION == 0
        float visibility = reflectionSkyLightWeight(lightmapLevel(geometry.b));
        vec4 cloud = cloudEnvironment(world);
        vec3 sky = cloud.rgb + skyAtmosphereRadiance(world) * (1.0 - cloud.a);
        vec3 skyEnvironment = sky * visibility + blockLightRadiance(lm);
        environment = mix(environment, skyEnvironment, reflectionSkyVisibility(world, m.roughness));
#endif
        environment = mix(environment, occlusion.rgb, occlusion.a);
        // Replace the forward environment instead of adding a second lobe.
        // Other reflective surfaces already carry a valid low-frequency radiance.
        vec3 specular = mix(environment, reflected.rgb, reflected.a) * fresnel - baseEnvironment;
        color = max(color + specular * (1.0 - getFogFactor(length(position))), vec3(0.0));
    }
#endif
    // Glass writes depth. Filling its background afterwards would leave black
    // behind every nonzero-alpha texel, even though clear glass holes look fine.
    gl_FragData[1] = vec4(color, 1.0);
    // 雾色差留到透明物与天气混合后统一修正，避免与 composite2 重复着色。
    gl_FragData[0] = vec4(color, 1.0);
#if DEBUG_VIEW == 0
    // 反射已读完不透明 G-Buffer，清出水面参数与独立透明层的存储位置。
    gl_FragData[2] = vec4(0.0);
    gl_FragData[3] = vec4(0.0);
#else
    gl_FragData[2] = texture2D(colortex1, uv);
    gl_FragData[3] = texture2D(colortex2, uv);
#endif
}
