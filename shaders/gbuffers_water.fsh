#version 120

/*
================================================================================
 gbuffers_water.fsh —— 水面片元着色器
================================================================================
 在标准地形光照之上，水面额外增加了两件事：

   1. 用波浪函数逐像素重新计算法线。
      顶点法线只有 4 个（一个水面方块就 4 个顶点），插值出来几乎是平的；
      而波浪的细节需要每像素都有不同的法线，所以在这里算。

   2. 高光（Blinn-Phong）。
      阳光照在水面上会产生一条"太阳反光带"，这是水面最标志性的特征。
      高光的方向性完全依赖法线，所以必须先有第 1 步。

 材质标记写 MAT_WATER，后处理阶段可以据此做：
   * 屏幕空间反射（SSR）
   * 更复杂的水体折射 / 吸收
   * 水下体积光
================================================================================
*/

#include "/lib/fragment_output.glsl"
#include "/lib/fog.glsl"
#include "/lib/water.glsl"


void main() {
    // 1. 材质颜色。水的贴图是灰白的，真正的蓝绿色来自生物群系染色（vColor）。
    //    水下看水面时游戏还会额外叠加一层蓝，这里不重复处理。
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);
    if (albedo.a < alphaTestRef) {
        discard;
    }

    // 2. 逐像素波浪法线
    vec3 normalView = vNormalView;

#if ENABLE_WATER_WAVES == 1
    vec3 faceNormalWorld = mat3(gbufferModelViewInverse) * vNormalView;
    if (faceNormalWorld.y > 0.9) {
    // 视图空间位置 -> 绝对世界坐标，拿到 xz 作为相位（与顶点着色器一致）。
    vec3 worldPos = viewToAbsoluteWorld(vViewPos);
    vec3 waveNormalWorld = getWaterWaveNormal(worldPos.xz, frameTimeCounter);

    // 世界空间法线 -> 视图空间法线。
    // 光照和阴影都在视图空间里算，所以必须转过来。
    normalView = safeNormalize(mat3(gbufferModelView) * waveNormalWorld, vNormalView);
    }
#endif

    // 3. 光照
    vec2 lmCoord    = prepareLightmapCoord(vLightmapCoord);
    vec3 lmColor    = sampleLightmapColor(lmCoord);
    float viewDistance = length(vViewPos);

    // 透明水面在基础管线里不接收自身阴影，避免从水下看时变成黑色片。
    float shadow = 1.0;
    vec3 color = computeLighting(albedo.rgb, normalView, lmColor, lmCoord, shadow);

    // 4. 高光。水是光滑表面，必然有明显的镜面反射。
    //    glossiness 取 300 左右能得到比较锐利的反光；
    //    调小到 50 会变成一片糊开的白色亮斑。
    //    只在有直射光的时候才有高光，所以乘上阴影系数。
    vec3 specular = computeSpecular(normalView, vViewPos, vec3(1.0), 300.0);
    color += specular * shadow * getDayFactor() * 0.8;

    // 5. 雾
    color = applyFog(color, viewDistance);
    if (isEyeInWater == 1) {
        // 水面底部即使背光，也应保留一部分散射光与周围水雾衔接。
        color = mix(color, getFogColor(), 0.35);
    }

    // 6. 写出。alpha 保持贴图的 alpha，
    //    由 OptiFine 的 alpha 混合状态决定它和背景怎么混合。
    writeGBuffers(color, normalView, lmCoord, shadow, MAT_WATER, albedo.a);
}
