/* Supply the sky before translucent blending, and preserve opaque HDR for water. */
/* RENDERTARGETS: 6,0,1,2 */
uniform sampler2D colortex1;
#include "../lib/sky_background.glsl"
#include "../lib/pbr_surface.glsl"
#include "../lib/clouds.glsl"
#include "../lib/wet_surface.glsl"

uniform sampler2D colortex0;
uniform sampler2D colortex2;
uniform sampler2D colortex14;
uniform sampler2D depthtex0;
#ifdef WORLD_GPU_BACKEND
uniform sampler2D colortex5;
#endif
#if ENABLE_MATERIAL_REFLECTIONS == 1
const bool colortex0MipmapEnabled = false;
#endif

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    float depth = texture2D(depthtex0, uv).r;
    vec4 opaque = texture2D(colortex0, uv);
    // Source alpha packs coverage (bit 0) and cutout class (bit 1). It is not
    // a blend opacity: a leaf hole containing a wall keeps the wall's coverage.
    float cutout = abs(texture2D(colortex1, uv).a - MAT_FOLIAGE) < 0.025 ? 2.0 : 0.0;
    vec4 reflectionSource = depth < 0.999999 ? vec4(opaque.rgb, 1.0 + cutout) : vec4(0.0);
#ifdef WORLD_GPU_BACKEND
    vec4 base = texture2D(colortex5, uv);
    if (depth < 0.999999 && base.a > 0.5) reflectionSource.rgb = base.rgb;
#endif
    vec3 color = fillSkyBackground(opaque.rgb, uv, depth);
    // 方块只保留漫反射/粗糙Glossy，场景辐射仍单独发布给水面使用。
    bool wetActive = ENABLE_RAIN_PUDDLES == 1 && weatherGroundWetness() * RAIN_PUDDLES_STRENGTH > 0.001;
    vec3 relative = vec3(0.0);
    float footprint = 0.0;
    if (wetActive) {
        relative = viewToWorld(screenToView(uv, min(depth, 0.99999)));
        footprint = max(length(dFdx(relative.xz)), length(dFdy(relative.xz)));
    }
    if (wetActive && depth < 0.999999) {
        vec4 geometry = texture2D(colortex1, uv);
        if (abs(geometry.a - MAT_WET_GROUND) < 0.025) {
            vec3 normal = decodeNormal(geometry.rg);
            vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * normal);
            vec4 physical = texture2D(colortex14, uv);
            float metallic = texture2D(colortex2, uv).a;
            vec2 wet = wetGroundCoverage(relative, worldNormal, geometry.b, metallic, footprint);
            color *= 1.0 - wet.x * 0.12 - wet.y * 0.18;
            if (wet.y > 0.015) {
                vec3 position = screenToView(uv, depth);
                vec3 view = normalize(-position);
                vec2 lightmap = texture2D(colortex2, uv).rg;
                SurfaceMaterial original;
                original.f0 = physical.rgb;
                original.roughness = max(physical.a, MATERIAL_GLOSS_ROUGHNESS);
                original.metallic = metallic;
                vec3 oldEnvironment = materialAmbientEnvironment(worldNormal, lightmap)
                    * materialEnvironmentWeight(original, dot(normal, view)) * MATERIAL_REFLECTION_STRENGTH;
                SurfaceMaterial coating;
                coating.f0 = vec3(0.025);
                coating.roughness = max(0.35, MATERIAL_GLOSS_ROUGHNESS);
                coating.metallic = 0.0;
                vec3 wetNormal = wetSurfaceNormal(normal, relative, wet.y, footprint);
                vec3 wetWorld = normalize(mat3(gbufferModelViewInverse) * wetNormal);
                vec3 environment = materialAmbientEnvironment(wetWorld, lightmap)
                    * materialEnvironmentWeight(coating, dot(wetNormal, view));
                vec3 tangent = mat3(gbufferModelView) * vec3(1.0, 0.0, 0.0);
                vec3 direct = materialDirectSpecular(coating, wetNormal, position, lightmap, vec3(1.0))
                    + pbrLocalGloss(coating, wetNormal, tangent, position, 0.0);
                color = max(color + (environment - oldEnvironment + direct) * wet.y
                    * (1.0 - getFogFactor(length(position))), vec3(0.0));
            }
        }
    }
#if defined(WORLD_GPU_BACKEND) && DEBUG_VIEW == 0
    if (depth < 0.999999) {
        color = applyFog(color, length(screenToView(uv, depth)));
    }
#endif
    // Glass writes depth. Filling its background afterwards would leave black
    // behind every nonzero-alpha texel, even though clear glass holes look fine.
    gl_FragData[1] = vec4(color, 1.0);
    // 雾色差留到透明物与天气混合后统一修正，避免与 composite2 重复着色。
#ifndef WORLD_GPU_BACKEND
    // 常规路径的反射源已包含相机雾；同步其天空色，避免雨天倒影保留旧蓝雾。
    // 主画面仍在透明物与雨层合成后独立修正，不重复修改显示颜色。
    if (depth < 0.999999) {
        reflectionSource.rgb = correctSkyFog(reflectionSource.rgb, uv,
            length(screenToView(uv, depth)), 1.0);
    }
#endif
    gl_FragData[0] = reflectionSource;
#ifdef WORLD_GPU_BACKEND
    gl_FragData[5] = vec4(0.0);
#endif
#if DEBUG_VIEW == 0
    // 反射已读完不透明 G-Buffer，清出水面参数与独立透明层的存储位置。
    gl_FragData[2] = vec4(0.0);
    gl_FragData[3] = vec4(0.0);
#else
    gl_FragData[2] = texture2D(colortex1, uv);
    gl_FragData[3] = texture2D(colortex2, uv);
#endif
}
