/* Screen-space intersections against the immutable opaque depth layer.
 * Only front-to-back crossings are refined. A local depth plane must then
 * intersect the ray inside its own pixel, so silhouettes cannot become hits.
 * Reconstructing geometry from depth also works during translucent rendering,
 * when the normal attachment no longer describes this opaque depth layer.
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

// The nearer depth neighbour on each axis avoids spanning a silhouette with
// the reconstructed plane. Its normal faces the camera, as visible geometry does.
bool reflectionSurfaceHit(sampler2D depths, vec3 origin, vec3 direction,
                          float range, inout vec2 uv, out float distanceToHit) {
    vec2 initialUv = uv;
    for (int attempt = 0; attempt < 3; attempt++) {
        vec2 pixelUv = reflectionPixelUv(uv);
        vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
        float depth = texture2D(depths, pixelUv).r;
        if (depth >= 0.999999) {
            return false;
        }
        vec3 centre = screenToView(pixelUv, depth);
        vec3 left = screenToView(pixelUv - vec2(texel.x, 0.0),
            texture2D(depths, pixelUv - vec2(texel.x, 0.0)).r);
        vec3 right = screenToView(pixelUv + vec2(texel.x, 0.0),
            texture2D(depths, pixelUv + vec2(texel.x, 0.0)).r);
        vec3 down = screenToView(pixelUv - vec2(0.0, texel.y),
            texture2D(depths, pixelUv - vec2(0.0, texel.y)).r);
        vec3 up = screenToView(pixelUv + vec2(0.0, texel.y),
            texture2D(depths, pixelUv + vec2(0.0, texel.y)).r);
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
            return false;
        }
        vec3 dx = abs(left.z - centre.z) < abs(right.z - centre.z) ? centre - left : right - centre;
        vec3 dy = abs(down.z - centre.z) < abs(up.z - centre.z) ? centre - down : up - centre;
        vec3 normal = safeNormalize(cross(dx, dy), vec3(0.0, 0.0, 1.0));
        normal *= dot(normal, -centre) >= 0.0 ? 1.0 : -1.0;
        float facing = dot(normal, direction);
        if (facing >= -0.001) {
            return false;
        }
        distanceToHit = dot(normal, centre - origin) / facing;
        if (distanceToHit <= 0.25 || distanceToHit > range) {
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

// Q=position/w and k=1/w interpolate linearly along the projected ray.
// The result stores hit UV, distance along the ray and edge/range confidence.
vec4 traceScreenReflection(sampler2D depths, vec3 origin, vec3 direction,
                           float range, int steps) {
    if (direction.z > 0.001) {
        range = min(range, (-near * 1.05 - origin.z) / direction.z);
    }
    if (range <= 0.25) {
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
    float stepT = endT * max(1.0 / float(steps), 1.0 / extent);
    float previousT = 0.0;
    float previousDelta = -origin.z - reflectionSceneDepth(depths, uv0);
    for (int index = 0; index < 64; index++) {
        if (index >= steps) {
            break;
        }
        float t = min(float(index + 1) * stepT, endT);
        vec2 uv = mix(uv0, uv1, t);
        float rayDepth = -mix(q0.z, q1.z, t) / mix(k0, k1, t);
        float difference = rayDepth - reflectionSceneDepth(depths, uv);
        if (previousDelta < 0.0 && difference >= 0.0) {
            float low = previousT;
            float high = t;
            for (int iteration = 0; iteration < 10; iteration++) {
                float mid = (low + high) * 0.5;
                vec2 testUv = mix(uv0, uv1, mid);
                float rayZ = -mix(q0.z, q1.z, mid) / mix(k0, k1, mid);
                if (rayZ >= reflectionSceneDepth(depths, testUv)) {
                    high = mid;
                } else {
                    low = mid;
                }
            }
            vec2 hitUv = mix(uv0, uv1, high);
            float distanceToHit;
            if (reflectionSurfaceHit(depths, origin, direction, range, hitUv, distanceToHit)) {
                vec2 edge = min(hitUv, 1.0 - hitUv);
                float confidence = smoothstep(0.0, 0.06, min(edge.x, edge.y))
                    * (1.0 - smoothstep(range * 0.75, range, distanceToHit));
                return vec4(hitUv, distanceToHit, confidence);
            }
        }
        previousT = t;
        previousDelta = difference;
        if (t >= endT) {
            break;
        }
    }
    return vec4(0.0);
}

#endif
