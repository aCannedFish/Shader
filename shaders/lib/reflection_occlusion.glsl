/* 相机看不到的倒影遮挡：沿反射光线在不透明阴影贴图里步进。
 *
 * 屏幕空间光线从树冠、桥面后方穿过时，深度缓冲无法区分“在几何体后方”与
 * “被几何体挡住”。阴影贴图从日月方向记录了另一层表面，可以补上这部分信息：
 *   - 光线点在贴图表面前方/后方的符号改变，且两侧贴图深度连续，
 *     说明光线穿过了真实表面。
 *       前 -> 后：从受光面进入实体，命中点就在穿越处。
 *       后 -> 前：从实体内部穿出受光面（桥底、树冠下方的水面），
 *                 之前已经打在相机和日月都看不到的背面上。
 *   - 贴图深度在穿越处跳变，说明只是穿过了阴影边界（空气），不算遮挡。
 * 前后判断留有死区，贴着地面掠过的光线不会因纹素量化被误判为进入地面。
 * 光线离开阴影贴图覆盖范围即停止，远处的遮挡仍由天光衰减近似。
 * 屏幕命中优先；只有遮挡点明显更近时（桥底、树冠下方）才取代屏幕命中。
 */
#ifndef LIB_REFLECTION_OCCLUSION_GLSL
#define LIB_REFLECTION_OCCLUSION_GLSL
#include "space.glsl"
#include "shadow_filter.glsl"
#include "material_environment.glsl"

// 步进距离（方块）：覆盖常见的树冠、桥面、屋檐高度。
const float REFLECTION_OCCLUSION_RANGE = 24.0;

// 光线点相对贴图表面的有符号距离（方块，正值在表面后方）。
// covered 为假表示已离开阴影贴图。
float reflectionShadowSeparation(vec3 clip, out bool covered) {
    vec3 coordinate = distortShadow(clip) * 0.5 + 0.5;
    covered = all(greaterThan(coordinate, vec3(0.0))) && all(lessThan(coordinate, vec3(1.0)));
    float mapDepth = texture2D(shadowtex1, shadowTexelCenter(coordinate.xy)).r;
    return shadowDepthToBlocks(coordinate.z - mapDepth);
}

// 点在相机深度缓冲之后（或在屏幕外）：相机看不到它，可能在实体内部。
bool reflectionHiddenFromCamera(sampler2D depths, vec3 pointView) {
    vec4 clip = gbufferProjection * vec4(pointView, 1.0);
    if (clip.w <= 0.0) {
        return true;
    }
    vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
        return true;
    }
    float depth = texture2D(depths, uv).r;
    return depth < 0.999999 && -pointView.z > -screenToView(uv, depth).z + 0.1;
}

// 返回 xyz：遮挡点（视图空间），w：1 表示被遮挡。
// hidden：命中的是相机看不到的面，不能直接取屏幕颜色。
vec4 reflectionShadowOcclusion(sampler2D depths, vec3 originView, vec3 directionView,
                               out bool hidden) {
    hidden = false;
#if REFLECTION_OCCLUSION_STEPS > 0 && ENABLE_SHADOWS == 1 && SIMPLE_DIMENSION == 0
    mat4 toShadow = shadowProjection * shadowModelView * gbufferModelViewInverse;
    // 实体侧面不受光，阴影贴图里看不到从侧面穿出的光线（桥底进、桥侧出）。
    // 穿出阴影区边界时若仍紧贴受光面之后（一格竖直厚度以内），
    // 且相机也看不到该点，视为在遮挡物内部。
    float sunHeight = abs((shadowModelView * vec4(0.0, 1.0, 0.0, 0.0)).z);
    float solidDepth = 1.0 / max(sunHeight, 0.3);
    // 正交投影：阴影裁剪坐标沿光线线性变化。
    vec3 clipOrigin = (toShadow * vec4(originView, 1.0)).xyz;
    vec3 clipDirection = mat3(toShadow) * directionView;
    float texelBlocks = 2.0 / (shadowTextureResolution()
                      * max(abs(shadowProjection[0][0]), EPSILON));
    float previousT = 0.0;
    float previousSeparation = 0.0;
    int previousState = 0;
    for (int index = 0; index <= REFLECTION_OCCLUSION_STEPS; index++) {
        // 二次分布：近处密、远处疏，先发现紧贴水面的树冠和桥底。
        float fraction = float(index) / float(REFLECTION_OCCLUSION_STEPS);
        float t = 0.25 + (REFLECTION_OCCLUSION_RANGE - 0.25) * fraction * fraction;
        vec3 clip = clipOrigin + clipDirection * t;
        // 畸变后的纹素在远处更大，按当前位置估计一个纹素对应的方块数。
        float distortion = (1.0 - SHADOW_MAP_BIAS) + length(clip.xy) * SHADOW_MAP_BIAS;
        // 径向是畸变最强的方向，用它作保守估计。
        float texel = texelBlocks * distortion * distortion / (1.0 - SHADOW_MAP_BIAS);
        bool covered;
        float separation = reflectionShadowSeparation(clip, covered);
        if (!covered) {
            break;
        }
        float deadZone = 0.15 + texel;
        int state = separation > deadZone ? 1 : (separation < -deadZone ? -1 : previousState);
        // 光线经阴影边界进入阴影区后，若紧贴某个受光面之后（两格竖直厚度以内）
        // 且相机也看不到，它已在该实体内部：山体侧面被树影遮住时，
        // 阴影贴图看不到入口，旧版因此透过叶丛露出天空。
        // 树冠、桥面下方的空气离受光的顶面至少隔着叶层或桥面本身，不受影响。
        vec3 point = originView + directionView * t;
        if (index > 0 && state > 0 && previousState > 0 && separation <= solidDepth * 2.0
            && reflectionHiddenFromCamera(depths, point)) {
            hidden = true;
            return vec4(point, 1.0);
        }
        if (index > 0 && previousState != 0 && state != previousState) {
            // 二分到约一个纹素，再看贴图深度在穿越处是否连续。
            float low = previousT;
            float high = t;
            float lowSeparation = previousSeparation;
            float highSeparation = separation;
            for (int iteration = 0; iteration < 5; iteration++) {
                float mid = (low + high) * 0.5;
                bool midCovered;
                float midSeparation = reflectionShadowSeparation(clipOrigin + clipDirection * mid,
                                                                 midCovered);
                if ((midSeparation > 0.0) == (highSeparation > 0.0)) {
                    high = mid;
                    highSeparation = midSeparation;
                } else {
                    low = mid;
                    lowSeparation = midSeparation;
                }
            }
            // 光线点本身最多移动 high-low；超出部分来自贴图深度跳变（阴影边界）。
            float jump = abs(highSeparation - lowSeparation) - (high - low);
            if (jump <= 0.35 + texel * 2.5) {
                hidden = state < 0;
                float hitT = state > 0 ? high : low;
                return vec4(originView + directionView * hitT, 1.0);
            }
            vec3 inside = originView + directionView * low;
            if (state < 0 && lowSeparation <= solidDepth
                && reflectionHiddenFromCamera(depths, inside)) {
                hidden = true;
                return vec4(inside, 1.0);
            }
        }
        if (state != 0) {
            previousState = state;
        }
        previousT = t;
        previousSeparation = separation;
    }
#endif
    return vec4(0.0);
}

// 阴影视图保留的原生材质提供离屏命中的颜色，避免整栋建筑退化成无纹理剪影。
// 只接受不透明/镂空材质，并核对两张深度：水和玻璃覆盖的颜色不能替代其后方表面。
vec3 reflectionShadowMaterial(vec3 hitView, vec3 ambient) {
    vec4 projected = shadowProjection * shadowModelView * gbufferModelViewInverse
        * vec4(hitView, 1.0);
    vec3 coordinate = distortShadow(projected.xyz / max(projected.w, EPSILON)) * 0.5 + 0.5;
    if (any(lessThan(coordinate, vec3(0.0))) || any(greaterThan(coordinate, vec3(1.0)))) {
        return ambient;
    }
    vec2 uv = shadowTexelCenter(coordinate.xy);
    vec4 material = texture2D(shadowcolor0, uv);
    bool opaque = abs(material.a - 1.0) < 0.08 || abs(material.a - 0.25) < 0.08;
    float separation = abs(shadowDepthToBlocks(texture2D(shadowtex0, uv).r
        - texture2D(shadowtex1, uv).r));
    if (!opaque || separation > 0.1) {
        return ambient;
    }
    // 回退环境原先含0.3平均反照率；现在改用采集到的实际反照率。
    return toLinearSpace(material.rgb) * ambient / 0.3;
}

// 遮挡点的辐射度：屏幕上可见时取屏幕颜色；被挡住的背面、底面只受环境光照亮，
// 用附近可见面的颜色压暗近似；离屏或投影落在天空上时用调用者给的暗环境色。
// scene 的 alpha 为几何覆盖率（材质通道的天空尚未填充）。
vec3 reflectionOccluderRadiance(sampler2D scene, sampler2D depths, vec3 hitView,
                                bool hidden, vec3 ambient) {
    vec3 materialFallback = reflectionShadowMaterial(hitView, ambient);
    vec4 clip = gbufferProjection * vec4(hitView, 1.0);
    if (clip.w <= 0.0) {
        return materialFallback;
    }
    vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
        return materialFallback;
    }
    float depth = texture2D(depths, uv).r;
    if (depth >= 0.999999) {
        return materialFallback;
    }
    float sceneDistance = -screenToView(uv, depth).z;
    float hitDistance = -hitView.z;
    // 可见面与遮挡点不在同一深度时，它是别的物体：更远的是透过叶隙看到的山，
    // 更近的是挡在前面的树叶、树干。借用它们压暗后的颜色会在倒影里
    // 沿前景轮廓画出细黑边，统一使用平滑的环境色。
    if (abs(sceneDistance - hitDistance) > max(1.0, hitDistance * 0.04)) {
        return materialFallback;
    }
    vec4 radiance = textureLod(scene, uv, 0.0);
    vec3 surface = radiance.rgb / max(radiance.a, 0.25);
    if (!hidden) {
        return surface;
    }
    // 同一物体的背面、底面：保留可见面的色相，亮度不超过环境光照明。
    return min(surface * 0.35, ambient * 2.0 + surface * 0.1);
}

// 被挡住的面朝向光线来处：陡直向上的光线打到底面（桥底、树冠下方），
// 只受下半球环境光；平缓的光线打到侧面（树影里的山坡），环境光更亮。
// 0.3 近似常见方块的反照率。rayWorld 为世界空间的反射方向。
vec3 reflectionHiddenAmbient(vec3 rayWorld, vec2 lmCoord) {
    return materialAmbientEnvironment(-rayWorld, lmCoord) * 0.3;
}

// rgb：遮挡物辐射度，a：遮挡权重。REFLECTION_OCCLUSION_STEPS 为 0 时恒为 0。
// hitDistance：遮挡点到起点的距离，未遮挡时为 0。
vec4 reflectionOcclusion(sampler2D scene, sampler2D depths, vec3 originView,
                         vec3 directionView, vec3 ambient, out float hitDistance) {
    bool hidden;
    vec4 hit = reflectionShadowOcclusion(depths, originView, directionView, hidden);
    hitDistance = 0.0;
    if (hit.w <= 0.0) {
        return vec4(0.0);
    }
    hitDistance = length(hit.xyz - originView);
    return vec4(reflectionOccluderRadiance(scene, depths, hit.xyz, hidden, ambient), 1.0);
}

// 遮挡点明显比屏幕命中近：屏幕光线从桥底、树冠下方穿过，在远处才打到
// 可见景物（桥后的树林、对岸的山），这个屏幕命中不是真正的倒影。
// 留出余量，同一表面上两种方法的命中误差不会互相覆盖。
bool reflectionOcclusionCloser(vec4 occlusion, float occlusionDistance, float screenDistance) {
    return occlusion.a > 0.0 && occlusionDistance < screenDistance * 0.8 - 1.0;
}

#endif
