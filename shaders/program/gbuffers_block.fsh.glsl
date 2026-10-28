#ifdef WORLD_GPU_BACKEND
/* RENDERTARGETS: 0,1,2,5 */
#else
/* RENDERTARGETS: 0,1,2,14 */
#endif

/*
 * 方块实体表面：床、箱子等模型采用与地形相同的环境光、局部光和日月阴影。
 * 此程序不负责选中框或挖掘裂纹，材质本身的白色不能作为自发光输出。
 */
#include "../lib/fragment_output.glsl"
#include "../lib/fog.glsl"
#include "../lib/material_lighting.glsl"
#include "../lib/pbr_surface.glsl"

// OptiFine resolves this ID through the same block.properties mapping.
uniform int blockEntityId;

void main() {
    vec2 materialUv = pbrParallaxUv(vTexCoord, vViewPos,
        safeNormalize(vNormalView, vec3(0.0, 1.0, 0.0)), vPbrTile);
    vec4 albedo = texture2D(texture, materialUv) * vColor;
    albedo.rgb = toLinearSpace(albedo.rgb);
    LabPbrMaterial pbr = readPbrSurface(albedo.rgb, materialUv);
    vec3 pbrNormal = pbrSurfaceNormal(safeNormalize(vNormalView, vec3(0.0, 1.0, 0.0)),
        vViewPos, vTexCoord, pbr.tangentNormal);
    if (albedo.a < alphaTestRef) {
        discard;
    }

    vec3 normalView = pbrNormal;
    vec2 lmCoord = prepareLightmapCoord(vLightmapCoord);
    float viewDistance = length(vViewPos);
    vec3 shadow = getShadowFactor(vShadowClipPos, normalView, viewDistance);
    vec3 reflectionSource;
    vec3 color = computePbrLighting(pbr, normalView, lmCoord, shadow,
        1.0, vViewPos, vTexCoord, reflectionSource);
    color = applySurfaceFog(color, viewDistance);
    writeGBuffers(color, normalView, lmCoord, shadow, MAT_SOLID, albedo.a);
#ifdef WORLD_GPU_BACKEND
    gl_FragData[3] = vec4(reflectionSource, 1.0);
#endif
    gl_FragData[2].a = pbr.metallic;
#ifndef WORLD_GPU_BACKEND
    gl_FragData[3] = vec4(pbr.f0, sqrt(pbr.roughness));
#endif
}
