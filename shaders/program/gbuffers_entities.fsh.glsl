#ifdef WORLD_GPU_BACKEND
/* RENDERTARGETS: 0,1,2,5 */
#else
/* RENDERTARGETS: 0,1,2,14,15 */
#endif

/*
================================================================================
 gbuffers_entities.fsh —— 实体片元着色器
================================================================================
 与地形的区别只有两点：
   1. 需要叠加 entityColor —— 生物受伤时全身闪红，
      游戏不改贴图，而是通过这个 uniform 传递"叠加色 + 强度"。
   2. 材质标记写成 MAT_ENTITY，方便后处理区分处理
      （例如给实体加轮廓光、或者做描边）。
================================================================================
*/

#include "../lib/fragment_output.glsl"
#include "../lib/fog.glsl"
#include "../lib/pbr_surface.glsl"


void main() {
    // 1. 材质颜色：贴图 × 顶点染色。
    //    生物的皮肤颜色、羊毛颜色、马的颜色等都在 vColor 里。
    vec2 materialUv = pbrParallaxUv(vTexCoord, vViewPos,
        safeNormalize(vNormalView, vec3(0.0, 1.0, 0.0)), vPbrTile);
    vec4 albedo = texture2D(texture, materialUv) * vColor;
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);
    LabPbrMaterial pbr = readPbrSurface(albedo.rgb, materialUv);
    vec3 pbrNormal = pbrSurfaceNormal(safeNormalize(vNormalView, vec3(0.0, 1.0, 0.0)),
        vViewPos, vTexCoord, pbr.tangentNormal);

    // 2. 受伤闪红。放在 alpha 测试之前也没关系，
    //    但放在之后可以少算一次被丢弃的像素，所以放在后面。
    albedo = applyEntityColor(albedo);

    if (albedo.a < alphaTestRef) {
        discard;
    }

    // 3. 光照
    vec3 normalView = pbrNormal;
    vec2 lmCoord    = prepareLightmapCoord(vLightmapCoord);
    vec3 lmColor    = sampleLightmapColor(lmCoord);
    float viewDistance = length(vViewPos);

    vec3 shadow = getShadowFactor(vShadowClipPos, normalView, viewDistance);
    vec3 reflectionSource;
    pbr.albedo = albedo.rgb;
    vec3 color = computePbrLighting(pbr, normalView, lmCoord, vec3(shadow),
        1.0, vViewPos, vTexCoord, reflectionSource);

    // 4. 雾 + 写出
    color = applySurfaceFog(color, viewDistance);

    writeGBuffers(color, normalView, lmCoord, shadow, MAT_ENTITY, albedo.a);
    gl_FragData[2].a = pbr.metallic;
#ifndef WORLD_GPU_BACKEND
    gl_FragData[3] = vec4(pbr.f0, sqrt(pbr.roughness));
#endif
}
