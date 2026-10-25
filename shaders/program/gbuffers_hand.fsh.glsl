#ifdef WORLD_GPU_BACKEND
/* RENDERTARGETS: 0,1,2,5 */
#else
/* RENDERTARGETS: 0,1,2 */
#endif

/* 手持模型片元阶段。使用与地形相同的光照模型，并缩短雾计算距离以保留近景可读性。
 */

#include "../lib/fragment_output.glsl"
#include "../lib/fog.glsl"


void main() {
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;
    // 光照在相同的线性空间中计算；透明度保持原值。
    albedo.rgb = toLinearSpace(albedo.rgb);
    if (albedo.a < alphaTestRef) {
        discard;
    }

    vec3 normalView = vNormalView;
    vec2 lmCoord    = prepareLightmapCoord(vLightmapCoord);
    vec3 lmColor    = sampleLightmapColor(lmCoord);
    float viewDistance = length(vViewPos);

    // 手持物品不受阴影影响：它离摄像机太近，阴影贴图在这个尺度上没有精度，
    // 硬算反而会出现一块块的黑斑。所以阴影系数直接给 1。
    float shadow = 1.0;

    vec3 color = computeLighting(albedo.rgb, normalView, lmColor, lmCoord, shadow, vViewPos);

    // 雾的"等效距离"放大 4 倍，等价于把手持物品放进更淡的雾里。
    // 想让手臂完全不受雾影响，把 4.0 改成 1000.0 即可。
    color = applySurfaceFog(color, viewDistance * 4.0);

    writeGBuffers(color, normalView, lmCoord, shadow, MAT_SOLID, albedo.a);
}
