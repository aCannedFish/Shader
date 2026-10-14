/*
================================================================================
 lib/vertex_transform.glsl —— gbuffers 顶点变换（顶点着色器专用）
================================================================================
 所有 gbuffers_* 程序的顶点着色器做的事情几乎一样：
   1. 把顶点从"世界空间"变换到"视图空间"，再投影到屏幕；
   2. 顺便把同一批数据用阴影摄像机的矩阵再变换一次，得到阴影采样坐标；
   3. 把法线、贴图坐标、光照贴图坐标、颜色等原样传给片元着色器。

 把这段逻辑抽出来，好处是：
   * 每个 gbuffers_*.vsh 只剩下不到 30 行，一眼能看完；
   * 想改坐标约定（例如加水面波浪、加模型动画），
     在这里改一次，所有程序同时生效，不会出现"某个程序忘了改"的 bug。

 【只应被 .vsh 引用】—— 它写入了 gl_Position，片元着色器里不存在这个变量。
================================================================================
*/
#ifndef LIB_VERTEX_TRANSFORM_GLSL
#define LIB_VERTEX_TRANSFORM_GLSL

#include "../settings.glsl"
#include "uniforms.glsl"
#include "common.glsl"
#include "space.glsl"
#include "varyings.glsl"


/*
 * 执行一次完整的 gbuffers 顶点变换。
 *
 * 参数（都来自顶点属性，没有的就是默认值）：
 *   position      模型空间顶点位置，通常来自 gl_Vertex
 *   normal        模型空间法线，通常来自 gl_Normal
 *   texCoord      已经由 gl_TextureMatrix[0] 变换的贴图坐标
 *   lightmapCoord 已经由 gl_TextureMatrix[1] 变换的光照贴图坐标
 *   color         顶点颜色，通常来自 gl_Color
 *   entityId      方块/实体 ID，mc_Entity
 *
 * 副作用：写入所有 varying 以及 gl_Position。
 */
void transformGBuffersVertex(vec3 position, vec3 normal, vec2 texCoord,
                             vec2 lightmapCoord, vec4 color, vec2 entityId) {
    // --- 1. 世界空间 -> 视图空间 ---
    // 模型空间因几何类型而异：地形属于区块，实体属于模型。
    // gl_ModelViewMatrix 包含当前绘制对象的变换；仅用全局
    // gbufferModelView 会漏掉区块平移，把大量顶点挤在原点附近。
    vec4 viewPos = gl_ModelViewMatrix * vec4(position, 1.0);
    vViewPos = viewPos.xyz;

    // --- 2. 视图空间 -> 裁剪空间 ---
    // 透视投影矩阵会把远处的顶点压向屏幕中心（近大远小），
    // 同时把 w 分量设成"到摄像机的距离"，为后面的透视除法做准备。
    gl_Position = gl_ProjectionMatrix * viewPos;

    // --- 3. 法线 ---
    // 只取左上角 3x3 做旋转，不平移。
    // 法线要用当前对象的逆转置矩阵，不能只用全局摄像机矩阵。
    // gl_Normal 有时是全零（例如粒子），safeNormalize 会退回 (0,0,1)，
    // 避免 normalize(0) 产生 NaN 把整块画面染黑。
    vNormalView = safeNormalize(gl_NormalMatrix * normal, vec3(0.0, 0.0, 1.0));

    // --- 4. 阴影坐标 ---
    // 视图空间先转回世界空间，再用太阳的矩阵变换到阴影裁剪空间。
    // 中间必须经过 gbufferModelViewInverse：shadowModelView 接受的是
    // 世界空间坐标，不是视图空间坐标。漏掉这一步会导致阴影完全错位。
    vec4 shadowClipPos = shadowProjection * shadowModelView * gbufferModelViewInverse * viewPos;

    // 只传线性投影；径向畸变由片元阶段执行，不能先畸变再插值。
    vShadowClipPos = shadowClipPos;

    // --- 5. 原样透传的属性 ---
    vTexCoord      = texCoord;
    vLightmapCoord = lightmapCoord;
    vEntityId      = entityId;

    // --- 6. 顶点颜色（有一个大坑） ---
    // 某些地形渲染路径的顶点 alpha 可能接近 0。
    //
    // 如果原样传到片元着色器，就会变成：
    //     albedo = texture2D(texture, uv) * vColor;   // albedo.a = 0
    //     if (albedo.a < alphaTestRef) discard;       // 0 < 0.1，全丢
    // 这种情况下，alpha 测试会丢弃地形像素。
    //
    // 处理办法和主流光影包一致：只把"接近 0"的 alpha 归一到 1，
    // 真正的半透明（粒子淡出等，alpha 在 0.1 以上）原样保留。
    vColor = color;
    if (vColor.a < 0.1) {
        vColor.a = 1.0;
    }
}

#endif  // LIB_VERTEX_TRANSFORM_GLSL
