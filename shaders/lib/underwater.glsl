/*
 * Underwater post-processing. Geometry is shaded before water attenuation.
 * Surface transmission uses Snell refraction and exact dielectric Fresnel/TIR.
 * Opaque depth preserves foreground occlusion. Reflected and transmitted rays
 * receive their own water path before composition; all geometry stays sharp.
 */
#ifndef LIB_UNDERWATER_GLSL
#define LIB_UNDERWATER_GLSL

#include "/lib/water_volume.glsl"

// Surface samples estimate physical immersion depth; light level is a fallback
// for views where the water surface lies outside the camera frustum.
float estimateUnderwaterDepth() {
    float result = 64.0;
    bool found = false;
    for (int x = 0; x < 3; x++) {
        for (int y = 0; y < 3; y++) {
            vec2 uv = vec2(0.15 + float(x) * 0.35, 0.73 + float(y) * 0.12);
            float depth = texture2D(colortex5, uv).a;
            if (depth > 0.001) {
                vec3 position = viewToAbsoluteWorld(waterSurfacePosition(uv, depth));
                float vertical = position.y - cameraPosition.y;
                if (vertical > 0.02) {
                    result = min(result, vertical);
                    found = true;
                }
            }
        }
    }
    if (!found) {
        float skylight = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
        result = (1.0 - skylight) * 15.0;
    }
    return clamp(result, 0.0, 64.0);
}

// Exact unpolarized dielectric Fresnel rises to 1 at the critical angle.
float underwaterFresnel(float cosine, float eta) {
    float sinTransmittedSquared = eta * eta * max(1.0 - cosine * cosine, 0.0);
    if (sinTransmittedSquared >= 1.0) {
        return 1.0;
    }
    float transmittedCosine = sqrt(max(1.0 - sinTransmittedSquared, 0.0));
    float s = (eta * cosine - transmittedCosine) / max(eta * cosine + transmittedCosine, EPSILON);
    float p = (cosine - eta * transmittedCosine) / max(cosine + eta * transmittedCosine, EPSILON);
    return clamp(0.5 * (s * s + p * p), 0.0, 1.0);
}

// Anchor geometry distortion to its height above the interface. Depth rejection
// and a shrinking offset retain continuous silhouettes when a new surface is hidden.
vec3 underwaterAirRadiance(vec2 uv, vec3 surfacePosition, vec3 airDirection, float skyVisibility) {
    vec3 originWorld = viewToAbsoluteWorld(surfacePosition);
    vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * airDirection);
    float depth = texture2D(depthtex1, uv).r;
    vec3 geometry = screenToView(uv, depth);
    vec3 geometryWorld = viewToAbsoluteWorld(geometry);
    bool nearGeometry = depth < 0.999999 && geometryWorld.y >= originWorld.y - 0.02
                     && length(geometry - surfacePosition) < 16.0;
    if (!nearGeometry) {
        // Refine the projected air path with the sampled depth instead of fixing
        // every object at 48 blocks. Near objects stay in the continuity path below.
        float distance = 48.0;
        vec2 selected = uv;
        bool valid = false;
        float residual = far;
        for (int iteration = 0; iteration < 5; iteration++) {
            valid = false;
            vec3 rayPosition = surfacePosition + airDirection * distance;
            vec4 target = gbufferProjection * vec4(rayPosition, 1.0);
            if (target.w <= 0.001) {
                break;
            }
            selected = target.xy / target.w * 0.5 + 0.5;
            if (any(lessThan(selected, vec2(0.002)))
                || any(greaterThan(selected, vec2(0.998)))) {
                break;
            }
            float sampledDepth = texture2D(depthtex1, selected).r;
            vec3 sampled = screenToView(selected, sampledDepth);
            vec3 sampledWorld = viewToAbsoluteWorld(sampled);
            residual = length(sampled - rayPosition);
            valid = sampledDepth < 0.999999 && sampledWorld.y >= originWorld.y - 0.02
                 && length(sampled - surfacePosition) >= 16.0;
            if (!valid || abs(airDirection.z) < 0.001) {
                break;
            }
            float refined = (sampled.z - surfacePosition.z) / airDirection.z;
            if (refined <= 0.0 || refined > far) {
                valid = false;
                break;
            }
            distance = refined;
        }
        if (valid && residual < 0.35 + distance * 0.01) {
            return texture2D(colortex6, selected).rgb;
        }
        return waterEnvironment(originWorld, rayWorld, skyVisibility, true);
    }

    float height = max(geometryWorld.y - originWorld.y, 0.0);
    float airPath = min(height / max(rayWorld.y, 0.12), 48.0);
    vec4 projected = gbufferProjection * vec4(surfacePosition + airDirection * airPath, 1.0);
    vec2 offset = vec2(0.0);
    if (projected.w > 0.001) {
        offset = projected.xy / projected.w * 0.5 + 0.5 - uv;
    }
    // Small displacements preserve gameplay readability and vanish at the waterline.
    vec2 pixels = offset * vec2(viewWidth, viewHeight);
    float limit = mix(0.0, 56.0, smoothstep(0.0, 2.0, height));
    offset *= min(1.0, limit / max(length(pixels), 0.001));
    vec2 selectedUv = uv;
    float scale = 1.0;
    for (int attempt = 0; attempt < 6; attempt++) {
        vec2 candidate = uv + offset * scale;
        if (all(greaterThan(candidate, vec2(0.002)))
            && all(lessThan(candidate, vec2(0.998)))) {
            float candidateDepth = texture2D(depthtex1, candidate).r;
            vec3 candidatePosition = screenToView(candidate, candidateDepth);
            vec3 candidateWorld = viewToAbsoluteWorld(candidatePosition);
            float depthDifference = abs(candidatePosition.z - geometry.z);
            if (candidateDepth < 0.999999 && candidateWorld.y >= originWorld.y - 0.02
                && depthDifference < max(0.5, -geometry.z * 0.08)) {
                selectedUv = candidate;
                break;
            }
        }
        scale *= 0.5;
    }
    return texture2D(colortex6, selectedUv).rgb;
}

vec3 applyUnderwaterOptics(vec2 uv, float sceneDepth) {
    float eyeDepth = estimateUnderwaterDepth();
    float opaqueDepth = texture2D(depthtex1, uv).r;
    vec3 opaquePosition = screenToView(uv, opaqueDepth);
    float sceneDistance = opaqueDepth < 0.999999 ? length(opaquePosition) : far;
    vec3 radiance = texture2D(colortex0, uv).rgb;
    // The transparent geometry pass has already blended a water film into colortex0.
    // Replace that film with opaque radiance before applying the single water volume.
    if (texture2D(colortex7, uv).a > 0.0) {
        radiance = texture2D(colortex6, uv).rgb;
    }
    vec4 surface = texture2D(colortex5, uv);
    float depthTolerance = max(0.015, surface.a * 0.0005);
    bool foreground = opaqueDepth < 0.999999 && -opaquePosition.z <= surface.a + depthTolerance;
    if (surface.a > 0.001 && !foreground) {
        vec3 position = waterSurfacePosition(uv, surface.a);
        vec3 world = viewToAbsoluteWorld(position);
        if (world.y > cameraPosition.y + 0.02) {
            vec3 normal = decodeWaterNormal(surface.xy);
            vec3 incident = normalize(position);
            if (dot(normal, -incident) < 0.0) {
                normal = -normal;
            }
            float waterPath = length(position);
            float cosine = clamp(dot(normal, -incident), 0.0, 1.0);
            // A finite rough interface spreads the critical-angle transition.
            float eta = mix(1.0, 1.333, WATER_REFRACTION_STRENGTH);
            float criticalCosine = sqrt(max(1.0 - 1.0 / (eta * eta), 0.0));
            float softness = UNDERWATER_SURFACE_SOFTNESS;
            float window = smoothstep(criticalCosine - softness, criticalCosine + softness, cosine);
            float safeCosine = clamp(max(cosine, criticalCosine + 0.015), 0.0, 1.0);
            float fresnel = 1.0 - window * (1.0 - underwaterFresnel(safeCosine, eta));
            // A single opaque layer cannot reconstruct a newly exposed near shore.
            // Keep its visible contour continuous rather than replacing it with a sky hole.
            vec3 opaqueWorld = viewToAbsoluteWorld(opaquePosition);
            if (opaqueDepth < 0.999999 && opaqueWorld.y >= world.y - 0.02) {
                float continuity = 1.0 - smoothstep(6.0, 16.0, length(opaquePosition - position));
                fresnel *= 1.0 - continuity * 0.90;
            }
            vec3 reflectedDirection = normalize(reflect(incident, normal));
            float reflectedDistance = 0.0;
            vec4 reflection = vec4(0.0);
            // In the transition, in-scattering dominates weak internal reflections.
            // This prevents two sharp geometry images from competing for the same pixel.
            float reflectionDetail = smoothstep(0.50, 0.90, fresnel);
            if (reflectionDetail > 0.001) {
                reflection = traceWaterScene(position + normal * 0.06,
                    reflectedDirection, true, reflectedDistance);
                reflection.a *= reflectionDetail;
            }
            // Attenuate each path separately. The reflected path must not darken transmission.
            vec3 reflected = underwaterScatterColor(eyeDepth);
            if (reflection.a > 0.0) {
                vec3 reflectedGeometry = applyUnderwaterVolume(reflection.rgb,
                    waterPath + reflectedDistance, eyeDepth);
                reflected = mix(reflected, reflectedGeometry, reflection.a);
            }
            vec3 transmitted = vec3(0.0);
            if (fresnel < 0.9999) {
                // Clamp the near-critical direction, rather than abruptly switching to a second image.
                vec3 tangent = safeNormalize(incident + normal * cosine, vec3(1.0, 0.0, 0.0));
                vec3 adjustedIncident = tangent * sqrt(max(1.0 - safeCosine * safeCosine, 0.0))
                                      - normal * safeCosine;
                vec3 airDirection = normalize(refract(adjustedIncident, normal, eta));
                transmitted = underwaterAirRadiance(uv, position, airDirection, surface.b);
                transmitted = applyUnderwaterVolume(transmitted, waterPath, eyeDepth);
            }
            return mix(transmitted, reflected, fresnel);
        }
    }
    return applyUnderwaterVolume(radiance, sceneDistance, eyeDepth);
}

#endif
