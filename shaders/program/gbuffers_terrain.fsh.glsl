
/*
================================================================================
 gbuffers_terrain.fsh —— 地形片元着色器
================================================================================
 这是整个光影包最值得逐行读完的文件。所有其它 gbuffers 程序都是它的简化版。

 计算流程（每一步在下面都有对应代码块）：

    贴图采样 ──> alpha 测试 ──┐
                              ├──> 光照 ──> 雾 ──> 写入 G-Buffer
    光照贴图采样 ─────────────┤
    阴影贴图采样 ─────────────┘

 最终写出的颜色是【线性空间】的 HDR 值（可能大于 1），
 色调映射与 gamma 编码留给后处理阶段的 final 程序统一处理。
 这样做的意义：所有光学混合（泛光、透明度、雾）都在物理正确的
 线性空间里进行，最后才转成显示器能看懂的信号。
================================================================================
*/

#include "../lib/fragment_output.glsl"   // 光照贴图、光照计算、写出 G-Buffer
#include "../lib/fog.glsl"                // 雾
#include "../lib/foliage_lighting.glsl"
#include "../lib/material_lighting.glsl"
#include "../lib/ore_emission.glsl"


void main() {
    /* =======================================================================
     * 第一步：材质颜色（Albedo）
     * ====================================================================
     * texture2D(texture, uv) 从方块图集里取出这一点的颜色。
     * 乘 vColor 是因为 MC 把生物群系染色放在顶点颜色里：
     *   草方块在平原偏黄绿、在沼泽偏灰绿，靠的就是这个乘法，
     *   同一张贴图能表现出不同生物群系的样子。
     *
     * albedo（反照率）的物理含义是"表面反射了多少比例的光"，
     * 它与"光照"是相乘的关系 —— 这就是为什么光照模型里到处都乘 albedo。
     */
    vec4 texel = texture2D(texture, vTexCoord);
    vec4 albedo = vec4(texel.rgb * vColor.rgb, texel.a);
    // separateAo 把原版环境遮蔽放在顶点 alpha，材质 alpha 保持贴图值。
    float occlusion = clamp(vColor.a, 0.0, 1.0);
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);

    /* =======================================================================
     * 第二步：alpha 测试
     * ====================================================================
     * 树叶、草、铁栏杆这类"镂空"贴图，被裁剪掉的部分 alpha 接近 0。
     * 不丢弃它们的话，这些像素会写进深度缓冲，让后面的东西被错误遮挡。
     *
     * alphaTestRef 是游戏传来的阈值（通常是 0.1）。
     * 对 gbuffers_terrain_a（半透明地形）这个值会被置为 0，
     * 于是这一步不会丢弃任何像素，半透明交给 alpha 混合处理。
     */
    if (albedo.a < alphaTestRef) {
        discard;
    }

    /* =======================================================================
     * 第三步：准备光照需要的输入
     * ==================================================================== */

    // 法线：视图空间，由顶点着色器插值而来。
    // 对平面方块来说三个顶点法线相同，插值结果仍是同一个方向；
    // 对平滑光照的模型（如台阶的圆弧）插值则会让法线在表面渐变，正是想要的效果。
    vec3 normalView = vNormalView;

    // 光照贴图坐标：x = 方块光（火把、萤石），y = 天空光（露天程度）。
    vec2 lmCoord = prepareLightmapCoord(vLightmapCoord);

    // 光照贴图颜色：MC 已经烘焙好的环境照明。
    // 火把附近偏橙、露天正午偏白、洞穴深处接近全黑。
    // 直接用它做环境光，比自己凭空造一个"天空光 + 点光源"要自然得多，
    // 而且开销几乎为零 —— 这正是 MC 光照系统的巧妙之处。
    vec3 lmColor = sampleLightmapColor(lmCoord);

    // 到摄像机的距离。视图空间里摄像机在原点，所以直接取长度。
    float viewDistance = length(vViewPos);

    // 材质标记：地形统一标记为"实心"。
    // 如果以后要给树叶、发光方块单独做处理，就在这里按 vEntityId 分类，
    // 改成写入 MAT_FOLIAGE 等其它值，后处理阶段就能识别出来。
    float material = MAT_SOLID;
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normalView);
    bool foliage = vEntityId.x >= 199.5 && vEntityId.x <= 204.5;
    bool special = vEntityId.x >= 99.5 && vEntityId.x < 199.5;
    if (normalWorld.y > 0.98 && texel.a > 0.99 && !foliage && !special) {
        material = MAT_WET_GROUND;
    }

    /* =======================================================================
     * 第四步：阴影
     * ====================================================================
     * getShadowFactor() 内部做的事（见 lib/shadow.glsl）：
     *   1. 把畸变后的裁剪空间坐标做透视除法，得到阴影贴图上的 UV 和深度
     *   2. 在 UV 周围采 3x3 个点，比较深度，得到 9 个"受光/被遮挡"的判断
     *   3. 求平均 -> 得到一个 0 到 1 之间的连续系数，软阴影就是这么来的
     */
    vec3 shadow = getShadowFactor(vShadowClipPos, normalView, viewDistance);

    /* =======================================================================
     * 第五步：光照
     * ====================================================================
     * computeLighting() 的公式（见 lib/lighting.glsl）：
     *
     *   颜色 = albedo × 环境光(光照贴图)              <- 火把、天空散射
     *        + albedo × 太阳颜色 × (N·L) × 阴影系数    <- 直射阳光
     *
     *   其中 N·L 是法线与光线方向的夹角余弦：
     *     N·L = 1  表面正对太阳，最亮
     *     N·L = 0  表面与光线平行，收不到光（背光面）
     */
    float kind = blockMaterialClass(vEntityId.x);
    vec3 color = computeMaterialLighting(albedo.rgb, normalView, lmCoord, shadow, occlusion, vViewPos, kind);
    color += foliageTransmittedLight(albedo.rgb, normalView, lmCoord, vShadowClipPos,
                                     vViewPos, vEntityId.x, occlusion);
    if (abs(vEntityId.x - 101.0) < 0.5) {
        // 自发光进入 HDR 泛光，源本身的亮度不受日照阴影或 AO 限制。
        color = max(color, albedo.rgb * 1.6);
    }
    color += oreEmission(vEntityId.x, vTexCoord, texel.rgb);

    /* =======================================================================
     * 第六步：雾
     * ====================================================================
     * 按距离把颜色混合向雾色，让远处自然融入天空。
     * 注意雾是在【线性空间】里混合的，物理上才正确
     * （在 gamma 空间混合会让远处的雾看起来偏暗、发灰）。
     */
    color = applyFog(color, viewDistance);

    /* =======================================================================
     * 第七步：写出 G-Buffer
     * ====================================================================
     * 一次写入三个渲染目标（MRT）：
     *   colortex0 <- 颜色（HDR）
     *   colortex1 <- 法线、天空光、材质标记
     *   colortex2 <- 方块光、天空光、阴影系数
     * 后处理程序稍后会读这些数据。
     */
    writeGBuffers(color, normalView, lmCoord, shadow, material, albedo.a);
    gl_FragData[2].a = packMaterial(kind, luma(albedo.rgb));


}
