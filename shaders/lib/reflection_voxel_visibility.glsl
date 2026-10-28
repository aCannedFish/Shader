/* 反射近场的首个实体命中。复用阴影阶段原生采集的体素，先挡住外墙，
 * 再允许屏幕颜色或阴影视图提供辐射；不从单层阴影深度猜测整个建筑内部。
 * 一格体素只用于不透明遮挡，水、玻璃和镂空植被继续使用原有光学路径。
 */
#ifndef LIB_REFLECTION_VOXEL_VISIBILITY_GLSL
#define LIB_REFLECTION_VOXEL_VISIBILITY_GLSL
#if defined(SIMPLE_VARYING) && GI_QUALITY > 0
#include "/lib/conventional_lpv.glsl"

vec4 reflectionNearestVoxel(vec3 originView, vec3 directionView, vec3 fallback,
                            out float hitDistance) {
    hitDistance = 0.0;
    if (!lpvHeaderValid(texelFetch(colortex8, ivec2(0), 0))) return vec4(0.0);
    vec3 originWorld = viewToAbsoluteWorld(originView);
    vec3 direction = normalize(mat3(gbufferModelViewInverse) * directionView);
    vec3 position = originWorld - vec3(lpvOrigin(cameraPosition));
    ivec3 cell = ivec3(floor(position));
    if (!lpvInside(cell)) return vec4(0.0);
    ivec3 stepDirection = ivec3(sign(direction));
    vec3 inverse = 1.0 / max(abs(direction), vec3(0.00001));
    vec3 boundary = vec3(cell) + step(vec3(0.0), direction);
    vec3 next = abs(boundary - position) * inverse;
    next = mix(vec3(1e20), next, notEqual(stepDirection, ivec3(0)));
    float distance = 0.0;
    vec3 normal = -direction;
    for (int index = 0; index < 192; index++) {
        if (!lpvInside(cell) || distance > 48.0) break;
        uint material = lpvVoxel(cell);
        // 量化体素覆盖整个接收方块。起点可能仍落在接收面所属格内，
        // 该格不能作为它自己的倒影；从第一次跨格之后才接受遮挡。
        if (index > 0 && lpvOpaque(material)) {
            hitDistance = max(distance, 0.001);
            vec3 colour = lpvColour(material);
            if (lpvKind(material) == LPV_EMITTER) {
                return vec4(colour * lpvEmission(material) / 15.0, 1.0);
            }
            float sky = lpvEmission(material) / 15.0;
            vec3 ambient = materialAmbientEnvironment(normal, vec2(0.03125, 0.03125 + sky * 0.9375));
            ambient = max(ambient, vec3(MIN_AMBIENT_LIGHT * AMBIENT_STRENGTH));
            ambient += lpvReadCell(cell + ivec3(round(normal)));
            vec3 point = originWorld + direction * distance + normal * 0.04;
            vec4 clip = shadowProjection * shadowModelView * vec4(point - cameraPosition, 1.0);
            vec3 shadow = distortShadow(clip.xyz / max(clip.w, EPSILON)) * 0.5 + 0.5;
            float visibility = 0.0;
            if (all(greaterThanEqual(shadow, vec3(0.0))) && all(lessThanEqual(shadow, vec3(1.0)))) {
                visibility = filteredShadowVisibility(shadowtex1, shadow.xy, shadow.z - 0.00015);
            }
            vec3 direct = getSunLightColor() * max(dot(normal, getSunDirWorld()), 0.0)
                * visibility * sky;
            return vec4(colour * (ambient + direct), 1.0);
        }
        float crossing = min(next.x, min(next.y, next.z));
        bvec3 advance = lessThanEqual(next, vec3(crossing + 0.000001));
        // 同时跨过相交轴；着色法线选择一个实际入射面，避免角点接触反复遮挡。
        normal = advance.x ? vec3(-float(stepDirection.x), 0.0, 0.0)
            : advance.y ? vec3(0.0, -float(stepDirection.y), 0.0)
            : vec3(0.0, 0.0, -float(stepDirection.z));
        cell += stepDirection * ivec3(advance);
        next += inverse * vec3(advance);
        distance = crossing;
    }
    return vec4(0.0);
}
#endif
#endif
