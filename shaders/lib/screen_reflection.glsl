/* Screen-space intersections against the immutable opaque depth layer.
 * Each sample is classified against the visible depth: in front, inside the
 * assumed object thickness, or deep behind. Entering the thickness band from
 * either side is refined by bisection. A local depth plane must then intersect
 * the ray inside its own pixel, so continuous surfaces give exact hits.
 * Reconstructing geometry from depth also works during translucent rendering,
 * when the normal attachment no longer describes this opaque depth layer.
 *
 * 深度缓冲只记录物体正面，不知道物体有多厚。参考 BSL 的厚度判断：
 *   - 光线进入可见表面后方一个物体厚度以内，视为打中该物体。
 *     连续表面用局部平面求出精确交点；轮廓像素和单像素的叶片、
 *     叶隙里露出的山体没有可用的切线，直接命中该像素（打进物体侧面）。
 *   - 光线从前景后方很深处穿过时不算命中；它之后可能从叶隙后方
 *     直接进入山体的厚度范围（深→内），同样会被细化并命中。
 *     旧版只检测前→后的穿越，透过树叶的倒影因此露出天空。
 *   - 前景挡住原本在光线后方的背景时，记住背景深度；光线在前景后方
 *     到达这个深度即命中背景（树叶、树干后方的山体），取背景的真实颜色。
 *   - 水面倒影裁掉水面以下的像素：河床既不会被打中，也不挡住光线。
 * 未命中时不猜测遮挡物：屏幕空间无法区分“在几何体后方”与“被几何体挡住”。
 * 旧版用压暗的轮廓颜色代替天空，倒影里出现大量细黑边。
 * 相机看不到的遮挡由 reflection_occlusion.glsl 用阴影贴图判断。
 * 命中距离没有远距离淡出：远处的山和树林也应出现在倒影里，而不是渐变成天空。
 */
#ifndef LIB_SCREEN_REFLECTION_GLSL
#define LIB_SCREEN_REFLECTION_GLSL
#include "space.glsl"

// Sample pixel centres explicitly; interpolated depth invents silhouette geometry.
vec2 reflectionPixelUv(vec2 uv) {
    vec2 size = vec2(viewWidth, viewHeight);
    return (clamp(floor(uv * size), vec2(0.0), size - 1.0) + 0.5) / size;
}

float reflectionSceneDepth(sampler2D depths, vec2 uv) {
    vec2 pixelUv = reflectionPixelUv(uv);
    float depth = texture2D(depths, pixelUv).r;
    return depth < 0.999999 ? -screenToView(pixelUv, depth).z : far;
}

// 光线可达的可见深度。clipPlane（视图空间，xyz 为法线）以下的像素视为空：
// 水面倒影的光线在水面之上，透过水面看到的河床既不会被打中，也不挡住任何
// 水面以上的东西。旧版先命中河床像素、再判定“在水下”而整条光线作废，
// 岸边与水中前景的倒影因此露出天空。xyz 为 0 时不裁剪。
float reflectionTraceDepth(sampler2D depths, vec2 uv, vec4 clipPlane) {
    vec2 pixelUv = reflectionPixelUv(uv);
    float depth = texture2D(depths, pixelUv).r;
    if (depth >= 0.999999) {
        return far;
    }
    vec3 point = screenToView(pixelUv, depth);
    return dot(clipPlane.xyz, point) + clipPlane.w < 0.0 ? far : -point.z;
}

// 天空邻居不能充当平面的切线：把它推到极远处，让另一侧被选为较近的邻居。
vec3 reflectionNeighbour(sampler2D depths, vec2 uv) {
    float depth = texture2D(depths, uv).r;
    if (depth >= 0.999999) {
        return vec3(0.0, 0.0, -1.0e6);
    }
    return screenToView(uv, depth);
}

// The nearer depth neighbour on each axis avoids spanning a silhouette with
// the reconstructed plane. Its normal faces the camera, as visible geometry does.
// pixelKind describes the first pixel when validation fails: 0 has a plane,
// 1 has no continuous neighbour on some axis (a one-pixel leaf, or background
// seen through a one-pixel gap), 2 is a grazing pixel spanning a large depth.
bool reflectionSurfaceHit(sampler2D depths, vec3 origin, vec3 direction,
                          float minDistance, float range, inout vec2 uv,
                          out float distanceToHit, out int pixelKind) {
    vec2 initialUv = uv;
    pixelKind = 0;
    distanceToHit = 0.0;
    for (int attempt = 0; attempt < 3; attempt++) {
        vec2 pixelUv = reflectionPixelUv(uv);
        vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
        float depth = texture2D(depths, pixelUv).r;
        if (depth >= 0.999999) {
            return false;
        }
        vec3 centre = screenToView(pixelUv, depth);
        vec3 left = reflectionNeighbour(depths, pixelUv - vec2(texel.x, 0.0));
        vec3 right = reflectionNeighbour(depths, pixelUv + vec2(texel.x, 0.0));
        vec3 down = reflectionNeighbour(depths, pixelUv - vec2(0.0, texel.y));
        vec3 up = reflectionNeighbour(depths, pixelUv + vec2(0.0, texel.y));
        // A one-pixel leaf or fence can have background on both sides. Those
        // neighbours provide no surface tangent; fitting them invents a sloped face.
        float continuity = max(0.05, -centre.z * 0.02);
        bool isolatedX = min(abs(left.z - centre.z), abs(right.z - centre.z)) > continuity
                      && (centre.z - left.z) * (right.z - centre.z) <= 0.0;
        bool isolatedY = min(abs(down.z - centre.z), abs(up.z - centre.z)) > continuity
                      && (centre.z - down.z) * (up.z - centre.z) <= 0.0;
        // A continuous grazing plane can change depth rapidly, but its two
        // one-sided slopes keep the same sign and must remain eligible for hits.
        if (isolatedX || isolatedY) {
            pixelKind = attempt == 0 ? 1 : pixelKind;
            return false;
        }
        vec3 dx = abs(left.z - centre.z) < abs(right.z - centre.z) ? centre - left : right - centre;
        vec3 dy = abs(down.z - centre.z) < abs(up.z - centre.z) ? centre - down : up - centre;
        // 地平线附近一个像素可以覆盖几十格深度，这样的像素既说不清平面在哪里，
        // 也会让几乎平行于平面的光线被误判为命中（倒影里出现一条亮线）。
        if (max(abs(dx.z), abs(dy.z)) > -centre.z * 0.3) {
            pixelKind = attempt == 0 ? 2 : pixelKind;
            return false;
        }
        vec3 normal = safeNormalize(cross(dx, dy), vec3(0.0, 0.0, 1.0));
        normal *= dot(normal, -centre) >= 0.0 ? 1.0 : -1.0;
        float facing = dot(normal, direction);
        if (facing >= -0.001) {
            return false;
        }
        distanceToHit = dot(normal, centre - origin) / facing;
        if (distanceToHit <= minDistance || distanceToHit > range) {
            return false;
        }
        vec4 clip = gbufferProjection * vec4(origin + direction * distanceToHit, 1.0);
        vec2 hitUv = clip.xy / clip.w * 0.5 + 0.5;
        vec2 error = abs(hitUv - pixelUv) / texel;
        if (clip.w <= 0.0) {
            return false;
        }
        uv = hitUv;
        if (max(error.x, error.y) <= 0.55) {
            return true;
        }
        // Raster depth is a staircase. Its first crossing can be in the pixel
        // next to the real plane hit; revalidate that pixel instead of dropping
        // alternating phases of an otherwise continuous reflected surface.
        vec2 relocation = abs(hitUv - initialUv) / texel;
        if (max(relocation.x, relocation.y) > 2.0) {
            return false;
        }
    }
    return false;
}

// 物体被当作实心体的厚度（方块）。远处深度与步进误差更大，容差随距离增加。
float reflectionThickness(float depth) {
    return max(0.5, depth * 0.025);
}

// 只在屏幕边缘淡出：靠近边缘的命中随时会随视角移出屏幕，提前过渡到环境。
float reflectionConfidence(vec2 uv) {
    vec2 edge = min(uv, 1.0 - uv);
    return smoothstep(0.0, 0.03, min(edge.x, edge.y));
}

// 一个轴上的轮廓：某侧邻居明显更远，且不在另一侧邻居延伸出的平面上。
// 平面上的 1/深度 随屏幕坐标线性变化；地平线附近的地面相邻两行可差几十格，
// 但三个像素的 1/深度 仍共线，它是连续平面而不是物体侧面。
bool reflectionSilhouetteAxis(float minus, float centre, float plus) {
    float gap = centre + max(0.25, centre * 0.03);
    float inverseCentre = 1.0 / centre;
    float slopeMinus = inverseCentre - 1.0 / minus;
    float slopePlus = 1.0 / plus - inverseCentre;
    float tolerance = 0.5 * min(abs(slopeMinus), abs(slopePlus)) + inverseCentre * 0.005;
    return max(minus, plus) > gap && abs(slopePlus - slopeMinus) > tolerance;
}

// 至少一侧邻居明显更远（含天空）：这个像素位于物体轮廓上。
bool reflectionSilhouette(sampler2D depths, vec2 pixelUv, float depth, vec4 clipPlane) {
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    return reflectionSilhouetteAxis(
               reflectionTraceDepth(depths, pixelUv - vec2(texel.x, 0.0), clipPlane), depth,
               reflectionTraceDepth(depths, pixelUv + vec2(texel.x, 0.0), clipPlane))
        || reflectionSilhouetteAxis(
               reflectionTraceDepth(depths, pixelUv - vec2(0.0, texel.y), clipPlane), depth,
               reflectionTraceDepth(depths, pixelUv + vec2(0.0, texel.y), clipPlane));
}

// Q=position/w and k=1/w interpolate linearly along the projected ray.
// The result stores hit UV, distance along the ray and edge confidence.
// minDistance rejects hits closer than this along the ray: an opaque receiver
// needs a small margin against itself, water has no receiver in the depth buffer.
// thinHit marks a pixel hit whose visible face is not the face struck.
vec4 traceScreenReflection(sampler2D depths, vec3 origin, vec3 direction,
                           float minDistance, float range, int steps, vec4 clipPlane,
                           out bool thinHit) {
    thinHit = false;
    if (direction.z > 0.001) {
        range = min(range, (-near * 1.05 - origin.z) / direction.z);
    }
    if (range <= minDistance) {
        return vec4(0.0);
    }
    vec4 startClip = gbufferProjection * vec4(origin, 1.0);
    vec4 endClip = gbufferProjection * vec4(origin + direction * range, 1.0);
    float k0 = 1.0 / startClip.w;
    float k1 = 1.0 / endClip.w;
    vec3 q0 = origin * k0;
    vec3 q1 = (origin + direction * range) * k1;
    vec2 uv0 = startClip.xy * k0 * 0.5 + 0.5;
    vec2 uv1 = endClip.xy * k1 * 0.5 + 0.5;
    // Spend the step budget on the visible segment, including camera-facing
    // rays whose untrimmed near-plane projection lies far outside the screen.
    vec2 delta = uv1 - uv0;
    vec2 boundary = mix(vec2(0.002), vec2(0.998), step(vec2(0.0), delta));
    vec2 exitT = (boundary - uv0) / (delta + mix(vec2(-EPSILON), vec2(EPSILON), step(vec2(0.0), delta)));
    float endT = clamp(min(exitT.x, exitT.y), 0.0, 1.0);
    float extent = max(abs(delta.x * viewWidth), abs(delta.y * viewHeight)) * endT;
    if (extent < 1.0) {
        return vec4(0.0);
    }
    vec2 pixelStep = normalize(delta * vec2(viewWidth, viewHeight)) / vec2(viewWidth, viewHeight);
    float stepT = endT * max(1.0 / float(steps), 1.0 / extent);
    float previousT = 0.0;
    float previousRay = -origin.z;
    // 0：在可见表面前方；1：在物体厚度以内；2：在可见表面后方很深处。
    // 起点（接收面本身）若已在厚度以内，不会触发命中。
    float startDepth = reflectionTraceDepth(depths, uv0, clipPlane);
    float startDelta = previousRay - startDepth;
    int previousState = startDelta < 0.0 ? 0 : (startDelta <= reflectionThickness(startDepth) ? 1 : 2);
    float previousScene = startDepth;
    vec2 previousUv = uv0;
    // 光线从可见背景前方转到前景物体后方时，记住被挡住的背景深度和像素。
    float coveredDepth = far;
    vec2 coveredUv = uv0;
    for (int index = 0; index < 64; index++) {
        if (index >= steps) {
            break;
        }
        float t = min(float(index + 1) * stepT, endT);
        vec2 uv = mix(uv0, uv1, t);
        float rayDepth = -mix(q0.z, q1.z, t) / mix(k0, k1, t);
        float sceneDepth = reflectionTraceDepth(depths, uv, clipPlane);
        float difference = rayDepth - sceneDepth;
        // 一步之内光线深度的变化也计入容差，粗步长不会从薄物体旁跳过。
        float band = reflectionThickness(sceneDepth) + abs(rayDepth - previousRay);
        int state = difference < 0.0 ? 0 : (difference <= band ? 1 : 2);
        // 前景（树干、树叶、栏杆）在这一步挡住了原本在光线后方的背景：
        // 背景多半在它后面继续延伸，记住背景深度和遮挡边缘处的背景像素。
        // 背景重新露出且光线仍在它前方时，前景已经过去，清除记录。
        // 起点像素是接收面本身（掠射时是它身后的同一平面），不能当作背景。
        if (index > 0 && previousState == 0 && previousScene > sceneDepth + band) {
            coveredDepth = previousScene;
            coveredUv = previousUv;
        } else if (state == 0) {
            if (sceneDepth > coveredDepth - reflectionThickness(coveredDepth)) {
                coveredDepth = far;
            }
        }
        // 前→后：陡峭的连续表面在一步之内深度变化很大，光线可能直接从前方
        // 跳到很深处，同样要找出穿越点；之后由厚度和平面验证区分
        // “打中表面”与“从细小前景后方经过”。
        bool entering = previousState == 0;
        if ((state == 1 && previousState != 1) || (state == 2 && entering)) {
            float low = previousT;
            float high = t;
            for (int iteration = 0; iteration < 10; iteration++) {
                float mid = (low + high) * 0.5;
                float lowRay = -mix(q0.z, q1.z, low) / mix(k0, k1, low);
                float highRay = -mix(q0.z, q1.z, high) / mix(k0, k1, high);
                float rayZ = -mix(q0.z, q1.z, mid) / mix(k0, k1, mid);
                float testDepth = reflectionTraceDepth(depths, mix(uv0, uv1, mid), clipPlane);
                float testDelta = rayZ - testDepth;
                if (testDelta >= 0.0 && (entering
                    || testDelta <= reflectionThickness(testDepth) + abs(highRay - lowRay))) {
                    high = mid;
                } else {
                    low = mid;
                }
            }
            vec2 hitUv = mix(uv0, uv1, high);
            vec3 crossing = mix(q0, q1, high) / mix(k0, k1, high);
            float front = reflectionTraceDepth(depths, hitUv, clipPlane);
            float gap = -crossing.z - front;
            if (gap >= -0.01 && gap <= reflectionThickness(front) && front < far) {
                vec2 surfaceUv = hitUv;
                float distanceToHit;
                int pixelKind;
                if (reflectionSurfaceHit(depths, origin, direction, minDistance, range,
                                         surfaceUv, distanceToHit, pixelKind)) {
                    return vec4(surfaceUv, distanceToHit, reflectionConfidence(surfaceUv));
                }
                // 没有平面可用的像素（轮廓、单像素叶片、叶隙中的山体）：
                // 光线在其表面后方一个厚度以内，视为打进这个物体。
                // 连续表面上的验证失败（掠射时的自身反射）不做处理。
                vec2 pixelUv = reflectionPixelUv(hitUv);
                distanceToHit = length(crossing - origin);
                if ((pixelKind == 1 || (pixelKind == 0 && reflectionSilhouette(depths, pixelUv, front, clipPlane)))
                    && distanceToHit > minDistance && distanceToHit <= range) {
                    // 沿光线再往前一个像素：若前景迅速变近，说明这是掠射平面
                    // （例如地平线附近的地面，一个像素覆盖几十格深度），
                    // 光线其实从它上方掠过，不能当作打进物体侧面。
                    float beyond = reflectionTraceDepth(depths, hitUv + pixelStep, clipPlane);
                    if (front - beyond <= reflectionThickness(front)) {
                        thinHit = true;
                        return vec4(pixelUv, distanceToHit, reflectionConfidence(pixelUv));
                    }
                }
                // 光线从正面进入了一个连续表面却没有命中（掠射的自身平面）：
                // 它没有从细小前景后方经过，近处的同一平面不是遮挡背景的前景。
                coveredDepth = far;
            }
        }
        // 光线在前景后方到达被挡背景的深度：视为打中背景。透过叶隙看到的山体、
        // 树干后的地面因此出现在倒影里，而不是天空；颜色是真实背景，不再压暗。
        float behind = rayDepth - coveredDepth;
        if (state != 0 && coveredDepth < far && behind >= 0.0
            && behind <= reflectionThickness(coveredDepth) + abs(rayDepth - previousRay)) {
            vec2 pixelUv = reflectionPixelUv(coveredUv);
            float coveredDistance = length(mix(q0, q1, t) / mix(k0, k1, t) - origin);
            if (coveredDistance > minDistance) {
                thinHit = true;
                return vec4(pixelUv, coveredDistance, reflectionConfidence(pixelUv));
            }
        }
        previousT = t;
        previousRay = rayDepth;
        previousState = state;
        previousScene = sceneDepth;
        previousUv = uv;
        if (t >= endT) {
            break;
        }
    }
    return vec4(0.0);
}

vec4 traceScreenReflection(sampler2D depths, vec3 origin, vec3 direction,
                           float minDistance, float range, int steps, out bool thinHit) {
    return traceScreenReflection(depths, origin, direction, minDistance, range, steps,
                                 vec4(0.0), thinHit);
}

vec4 traceScreenReflection(sampler2D depths, vec3 origin, vec3 direction,
                           float range, int steps) {
    bool thinHit;
    return traceScreenReflection(depths, origin, direction, 0.05, range, steps, thinHit);
}

#endif
