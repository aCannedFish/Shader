
/*
================================================================================
 gbuffers_textured.fsh —— 带贴图、不受阳光直射影响的几何体
================================================================================
 与 basic 的区别：
   * 材质颜色 = 贴图 × 顶点颜色
   * 只乘光照贴图的颜色，不做直射光/阴影计算 —— 这类几何体（粒子等）
     在 MC 里本来就不投射阴影，硬加上阴影反而会出现"粒子被自己的影子切一半"
     的怪异现象。
================================================================================
*/

#include "../lib/fragment_output.glsl"
#if defined(WORLD_GPU_BACKEND) && DEBUG_VIEW == 0
/* RENDERTARGETS: 0,1 */
#else
/* RENDERTARGETS: 0,1,2,14,15 */
#endif

#include "../lib/fog.glsl"
#include "../lib/rain_particles.glsl"


void main() {
    // 1. 材质颜色 = 图集上的贴图 × 顶点染色
    //    texture2D(采样器, 坐标) 是 GLSL 120 的纹理采样函数
    //    （GLSL 330 之后改名为 texture()，本项目统一用 120 的写法）
    vec4 texel = texture2D(texture, vTexCoord);
    vec4 albedo = texel * vColor;
    vec3 rawAlbedo = albedo.rgb;
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);

    // 2. alpha 测试：透明像素丢弃
    if (albedo.a < alphaTestRef) {
        discard;
    }

    // 3. 只受环境光影响：直接乘光照贴图颜色。
    //    这样夜里/洞里粒子会自然变暗，但不会被阳光的阴影切成两半。
    vec2 lmCoord = prepareLightmapCoord(vLightmapCoord);
    vec3 lmColor = sampleLightmapColor(lmCoord);
    vec3 color = albedo.rgb * lmColor * AMBIENT_STRENGTH;
    vec4 rainLayer;
    color = shadeRainParticle(color, rawAlbedo, lmCoord, albedo.a, rainLayer);

    // 4. 雾
    float viewDistance = length(vViewPos);
    color = applyRainParticleFog(color, rawAlbedo, viewDistance, albedo.a, rainLayer);

    // 5. 写出。阴影系数填 1（不受阴影影响），材质标记用 SOLID。
    //    即使不参与阴影，也要往 colortex2 写字，
    //    否则缓冲区里会残留上一帧的数据，调试视图会看到脏东西。
    writeGBuffers(color, vNormalView, lmCoord, 1.0, MAT_SOLID, albedo.a);
#if defined(WORLD_GPU_BACKEND) && DEBUG_VIEW == 0
    // Particle geometry must not overwrite water R/G or the glass colour layer.
    gl_FragData[1] = rainLayer;
#endif
}
