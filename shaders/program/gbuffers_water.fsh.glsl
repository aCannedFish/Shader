
/*
 * 半透明水材质：局部光照贴图提供漫反射，天光与不透明阴影限制日/月高光。
 * colortex5 单独保存波浪法线、天光可见度和线性深度，供 composite 计算倒影。
 * 其它半透明方块沿用普通材质光照，不写入水面反射标记。
 */
/* RENDERTARGETS: 0,1,2,5,7 */

#include "../lib/fragment_output.glsl"
#include "../lib/fog.glsl"
#include "../lib/water.glsl"
#include "../lib/water_surface.glsl"
#include "../lib/rain_ripples.glsl"
#include "../lib/water_lighting.glsl"
#include "../lib/material_lighting.glsl"
#include "../lib/material_reflection.glsl"
uniform sampler2D colortex6;
uniform sampler2D depthtex1;

void main() {
    vec3 worldPosition = viewToAbsoluteWorld(vViewPos);
    float waveFootprint = max(length(dFdx(worldPosition.xz)), length(dFdy(worldPosition.xz)));
    bool water = abs(vEntityId.x - WATER_BLOCK_ID) < 0.5;
    float kind = blockMaterialClass(vEntityId.x);
    bool glass = !water && kind > 11.5 && kind < 12.5 && MATERIAL_REFLECTION_STRENGTH > 0.0;
    vec4 texel = texture2D(texture, vTexCoord);
#if ENABLE_WATER_TEXTURE == 0
    if (water) {
        texel.rgb = vec3(1.0);
    }
#endif
    vec3 albedoColor = water
        ? toLinearSpace(texel.rgb) * waterScatteringAlbedo(vColor.rgb)
        : toLinearSpace(texel.rgb * vColor.rgb);
    vec4 albedo = vec4(albedoColor, texel.a * vColor.a);
    if (!glass && (albedo.a <= 0.001 || albedo.a < alphaTestRef)) {
        discard;
    }

    vec3 normalView = safeNormalize(vNormalView, vec3(0.0, 1.0, 0.0));
    vec3 faceNormalWorld = mat3(gbufferModelViewInverse) * normalView;
    bool topSurface = water && abs(faceNormalWorld.y) > 0.9;
#if ENABLE_WATER_WAVES == 1
    if (topSurface) {
        vec3 waveNormalWorld = waterSurfaceNormal(worldPosition.xz, frameTimeCounter, waveFootprint);
        vec2 rainSlope = rainRippleSlope(worldPosition.xz, frameTimeCounter, waveFootprint)
            * smoothstep(0.95, 0.995, waterSkyLevel(vLightmapCoord.y));
        waveNormalWorld = normalize(waveNormalWorld + vec3(-rainSlope.x, 0.0, -rainSlope.y));
        float orientation = isEyeInWater == 1 ? -1.0 : 1.0;
        vec3 waveView = mat3(gbufferModelView) * waveNormalWorld * orientation;
        float grazing = abs(dot(normalView, normalize(-vViewPos)));
        // 细节法线没有独立几何遮挡，掠射时限制斜率，避免假背面产生黑色空洞。
        float slopeWeight = mix(0.35, 1.0, smoothstep(0.02, 0.20, grazing));
        normalView = safeNormalize(mix(normalView, waveView, slopeWeight), normalView);
    }
#endif

    vec2 lmCoord = prepareLightmapCoord(vLightmapCoord);
    vec3 lmColor = sampleLightmapColor(lmCoord);
    float viewDistance = length(vViewPos);
    float skyVisibility = waterSkyVisibility(lmCoord.y);
    float directSky = smoothstep(0.60, 0.96, waterSkyLevel(lmCoord.y));
    float shadow = 1.0;
    if (directSky > 0.001) {
        shadow = waterOpaqueShadow(vShadowClipPos, normalView, viewDistance);
        shadow *= cloudProjectedShadow(viewToAbsoluteWorld(vViewPos),
            normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
    }
    float directVisibility = shadow * directSky;
    vec3 color;
    vec3 scatteringRadiance = vec3(0.0);
    if (water) {
        color = waterDiffuse(albedo.rgb, normalView, lmCoord, directVisibility, vViewPos);
        scatteringRadiance = color;
        albedo.a *= WATER_SURFACE_OPACITY;
        // 合成阶段会在最终水面颜色上计算 GGX 高光；这里的颜色会被覆盖。
        // 封闭水域的散射颜色也必须随当地光照衰减。
        // 与 waterScatteringAlbedo 一致的暗青色，不再是偏重的蓝。
        vec3 scatter = mix(lmColor * vec3(0.06, 0.20, 0.23), getFogColor(), skyVisibility);
        color = mix(color, scatter, getFogFactor(viewDistance));
    } else {
        color = computeLighting(albedo.rgb, normalView, lmColor, lmCoord, shadow, vViewPos);
        if (abs(vEntityId.x - 101.0) < 0.5) {
            color = max(color, albedo.rgb * 1.6);
        }
#if ENABLE_MATERIAL_REFLECTIONS == 1
        if (kind > 0.5 && MATERIAL_REFLECTION_STRENGTH > 0.0) {
            normalView *= dot(normalView, -vViewPos) >= 0.0 ? 1.0 : -1.0;
            SurfaceMaterial m = surfaceMaterial(kind, luma(albedo.rgb));
            vec3 incident = normalize(vViewPos);
            vec3 direction = reflect(incident, normalView);
            vec4 hit = traceMaterialScene(colortex6, depthtex1, vViewPos + normalView * 0.003,
                                          direction, normalView, m.roughness);
            vec3 world = normalize(mat3(gbufferModelViewInverse) * direction);
            vec3 environment = materialAmbientEnvironment(world, lmCoord);
            vec3 fresnel = materialEnvironmentWeight(m, dot(normalView, -incident))
                         * MATERIAL_REFLECTION_STRENGTH;
            float alpha = clamp(albedo.a, 0.0, 1.0);
            float reflectionAlpha = max(max(fresnel.r, fresnel.g), fresnel.b);
            albedo.a = alpha + (1.0 - alpha) * reflectionAlpha;
            vec3 reflection = mix(environment, hit.rgb, hit.a) * fresnel;
            reflection += materialDirectSpecular(m, normalView, vViewPos, lmCoord, vec3(shadow))
                        * MATERIAL_REFLECTION_STRENGTH;
            // Convert the optical result to straight alpha for the loader's blend.
            // Reflection stays visible in clear glass texels whose texture alpha is zero.
            color = (color * alpha * (1.0 - fresnel) + reflection) / max(albedo.a, 0.001);
        }
#endif
        color = applyFog(color, viewDistance);
    }

    // 光学密度保存在 colortex7，低 alpha 不能让加载器丢掉水面几何数据。
    float outputAlpha = water ? max(albedo.a, alphaTestRef) : albedo.a;
    writeGBuffers(color, normalView, lmCoord, shadow, water ? MAT_WATER : MAT_SOLID, outputAlpha);
    // 水面数据以二值 alpha 替换，玻璃输出零值并保留它；玻璃颜色另存预乘层。
    // 线性深度位于 B，alpha 专门用于覆盖标记，避免透明混合破坏水面深度。
#ifdef WORLD_PACKED_WATER
    gl_FragData[3] = topSurface
        ? packWaterSurface(encodeWaterNormal(normalView), max(-vViewPos.z, 0.0), scatteringRadiance)
        : vec4(0.0);
#else
    gl_FragData[3] = topSurface
        ? vec4(encodeWaterNormal(normalView), max(-vViewPos.z, 0.0), 1.0) : vec4(0.0);
    gl_FragData[4] = topSurface ? vec4(scatteringRadiance, 1.0) : vec4(0.0);
#endif
#if DEBUG_VIEW == 0
    gl_FragData[1] = topSurface ? vec4(skyVisibility, albedo.a, 0.0, 1.0) : vec4(0.0);
    gl_FragData[2] = water ? vec4(0.0) : vec4(color * outputAlpha, outputAlpha);
#endif
}
