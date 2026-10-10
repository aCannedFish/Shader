#version 120

/*
 * 半透明水材质：局部光照贴图提供漫反射，天光与不透明阴影限制日/月高光。
 * colortex5 单独保存波浪法线、天光可见度和线性深度，供 composite 计算倒影。
 * 其它半透明方块沿用普通材质光照，不写入水面反射标记。
 */
/* RENDERTARGETS: 0,1,2,5,7 */

#include "lib/fragment_output.glsl"
#include "lib/fog.glsl"
#include "lib/water.glsl"
#include "lib/water_lighting.glsl"

void main() {
    bool water = abs(vEntityId.x - WATER_BLOCK_ID) < 0.5;
    vec4 texel = texture2D(texture, vTexCoord);
#if ENABLE_WATER_TEXTURE == 0
    if (water) {
        texel.rgb = vec3(1.0);
    }
#endif
    vec3 tint = vColor.rgb;
    if (water) {
        // 浅青色仅调整水材质，反射中的物体仍保留自身颜色。
        tint = mix(tint, vec3(0.62, 0.83, 0.88), WATER_COLOR_LIGHTNESS);
    }
    vec4 albedo = vec4(toLinearSpace(texel.rgb * tint), texel.a * vColor.a);
    if (albedo.a <= 0.001 || albedo.a < alphaTestRef) {
        discard;
    }

    vec3 normalView = safeNormalize(vNormalView, vec3(0.0, 1.0, 0.0));
    vec3 faceNormalWorld = mat3(gbufferModelViewInverse) * normalView;
    bool topSurface = water && abs(faceNormalWorld.y) > 0.9;
#if ENABLE_WATER_WAVES == 1
    if (topSurface) {
        vec3 worldPos = viewToAbsoluteWorld(vViewPos);
        vec3 waveNormalWorld = getWaterWaveNormal(worldPos.xz, frameTimeCounter);
        float orientation = isEyeInWater == 1 ? -1.0 : 1.0;
        normalView = safeNormalize(mat3(gbufferModelView) * waveNormalWorld * orientation, normalView);
    }
#endif

    vec2 lmCoord = prepareLightmapCoord(vLightmapCoord);
    vec3 lmColor = sampleLightmapColor(lmCoord);
    float viewDistance = length(vViewPos);
    float skyVisibility = waterSkyVisibility(lmCoord.y);
    float shadow = waterOpaqueShadow(vShadowClipPos, normalView, viewDistance);
    shadow *= cloudProjectedShadow(viewToAbsoluteWorld(vViewPos),
        normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
    float directVisibility = shadow * smoothstep(0.60, 0.96, waterSkyLevel(lmCoord.y));
    vec3 color;
    vec3 scatteringRadiance = vec3(0.0);
    if (water) {
        color = waterDiffuse(albedo.rgb, normalView, lmCoord, directVisibility, vViewPos);
        scatteringRadiance = color;
        albedo.a *= WATER_SURFACE_OPACITY;
        if (isEyeInWater == 0) {
            color += waterDirectSpecular(normalView, vViewPos) * directVisibility
                   * WATER_REFLECTION_STRENGTH * WATER_SPECULAR_STRENGTH;
        }
        // 封闭水域的散射颜色也必须随当地光照衰减。
        vec3 scatter = mix(lmColor * vec3(0.08, 0.22, 0.35), getFogColor(), skyVisibility);
        color = mix(color, scatter, getFogFactor(viewDistance));
    } else {
        color = computeLighting(albedo.rgb, normalView, lmColor, lmCoord, shadow, vViewPos);
        if (abs(vEntityId.x - 101.0) < 0.5) {
            color = max(color, albedo.rgb * 1.6);
        }
        color = applyFog(color, viewDistance);
    }

    // 光学密度保存在 colortex7，低 alpha 不能让加载器丢掉水面几何数据。
    float outputAlpha = water ? max(albedo.a, alphaTestRef) : albedo.a;
    writeGBuffers(color, normalView, lmCoord, shadow, water ? MAT_WATER : MAT_SOLID, outputAlpha);
    // 禁用此附件的混合，避免地形法线/材质标记混进透明水面的数据。
    // 线性视图深度避免透明深度状态和硬件深度精度影响折射起点。
    float surfaceDepth = topSurface ? max(-vViewPos.z, 0.0) : 0.0;
    gl_FragData[3] = vec4(encodeWaterNormal(normalView), skyVisibility, surfaceDepth);
    gl_FragData[4] = vec4(scatteringRadiance, water ? albedo.a : 0.0);
}
