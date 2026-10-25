#ifdef WORLD_GPU_BACKEND
/* RENDERTARGETS: 0,1,2,5 */
#else
/* RENDERTARGETS: 0,1,2 */
#endif

/*
 * 方块实体表面：床、箱子等模型采用与地形相同的环境光、局部光和日月阴影。
 * 此程序不负责选中框或挖掘裂纹，材质本身的白色不能作为自发光输出。
 */
#include "../lib/fragment_output.glsl"
#include "../lib/fog.glsl"
#include "../lib/material_lighting.glsl"

// OptiFine resolves this ID through the same block.properties mapping.
uniform int blockEntityId;

void main() {
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;
    albedo.rgb = toLinearSpace(albedo.rgb);
    if (albedo.a < alphaTestRef) {
        discard;
    }

    vec3 normalView = safeNormalize(vNormalView, vec3(0.0, 1.0, 0.0));
    vec2 lmCoord = prepareLightmapCoord(vLightmapCoord);
    float viewDistance = length(vViewPos);
    vec3 shadow = getShadowFactor(vShadowClipPos, normalView, viewDistance);
    float kind = blockMaterialClass(float(blockEntityId));
    vec3 reflectionSource;
    vec3 color = computeMaterialLighting(albedo.rgb, normalView, lmCoord, shadow,
        1.0, vViewPos, kind, reflectionSource);
    color = applySurfaceFog(color, viewDistance);
    writeGBuffers(color, normalView, lmCoord, shadow, MAT_SOLID, albedo.a);
#ifdef WORLD_GPU_BACKEND
    gl_FragData[3] = vec4(reflectionSource, 1.0);
#endif
    gl_FragData[2].a = packMaterial(kind, luma(albedo.rgb));
}
