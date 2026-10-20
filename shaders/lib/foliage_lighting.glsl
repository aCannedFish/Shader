/* 薄植被的逆光透射。只对已映射的树叶、草木、庄稼生效，使用日月阴影中
 * 最近投影体的类别和厚度限制透光；实体墙、厚叶团及阴影范围外均不补光。
 * 这是一层薄材质近似，不追踪多次内部散射，也不改变方块透明度。
 */
#ifndef LIB_FOLIAGE_LIGHTING_GLSL
#define LIB_FOLIAGE_LIGHTING_GLSL
#include "lighting.glsl"
#include "shadow_filter.glsl"

// 阴影的 alpha=0.25 标记薄植被。单层透射受沿光线厚度限制，四点核软化
// 低分辨率阴影中的类别边界；普通阴影仍把这些投影体当作不透明遮挡。
float foliageShadowTransmission(vec4 clipPosition, vec3 normalView, float distance) {
#if ENABLE_SHADOWS == 0 || SIMPLE_DIMENSION != 0
    return 0.0;
#else
    vec3 uv;
    vec2 gradient;
    float receiver;
    float fade;
    float distortion;
    // 透射发生在背光面，用反向法线完成已有的接收端设置与斜率补偿。
    if (!prepareDirectionalShadow(clipPosition, -normalView, distance,
                                  uv, gradient, receiver, fade, distortion)) {
        return 0.0;
    }
    float transmission = 0.0;
    float texel = 1.0 / shadowTextureResolution();
    for (int index = 0; index < 4; index++) {
        vec2 tap = shadowTexelCenter(uv.xy + shadowDiskOffset(index, 4) * texel);
        if (abs(texture2D(shadowcolor0, tap).a - 0.25) > 0.08) {
            continue;
        }
        float sampleReceiver = receiver + dot(gradient, tap - uv.xy);
        float thickness = shadowDepthToBlocks(max(sampleReceiver - texture2D(shadowtex0, tap).r, 0.0));
        // 方块叶片的前后表面约隔一格；约 1.5 格后完全截止，厚树冠不整体发亮。
        transmission += exp(-thickness * 1.5) * (1.0 - smoothstep(1.0, 1.5, thickness));
    }
    return transmission * 0.25 * fade;
#endif
}

vec3 foliageTransmittedLight(vec3 albedo, vec3 normalView, vec2 lmCoord,
                            vec4 shadowClip, vec3 viewPosition, float material, float occlusion) {
    if (FOLIAGE_TRANSLUCENCY <= 0.0 || material < 199.5 || material > 204.5) {
        return vec3(0.0);
    }
    float transmission = foliageShadowTransmission(shadowClip, normalView, length(viewPosition));
    if (transmission <= 0.0) {
        return vec3(0.0);
    }
    vec3 light = getLightDirView();
    float back = max(dot(-normalView, light), 0.0);
    float exposure = smoothstep(0.60, 0.96, lightmapLevel(lmCoord.y));
    vec3 radiance = getSunLightColor() + getMoonLightColor();
    if (back <= 0.0 || exposure <= 0.0 || !any(greaterThan(radiance, vec3(0.0)))) {
        return vec3(0.0);
    }
    vec3 world = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz + cameraPosition;
    float cloud = cloudProjectedShadow(world, normalize(mat3(gbufferModelViewInverse) * light));
    vec3 view = safeNormalize(-viewPosition, normalView);
    float forward = pow(max(dot(view, -light), 0.0), 4.0);
    float directional = back * (0.35 + 0.65 * forward);
    // 薄叶的色相来自材质自身；平方根项只让透射比表面反射略浅，避免统一染黄。
    vec3 tint = mix(albedo, sqrt(max(albedo, vec3(0.0))), 0.35);
    return tint * radiance * transmission * directional * exposure * cloud
         * FOLIAGE_TRANSLUCENCY * mix(0.5, 1.0, occlusion);
}
#endif
