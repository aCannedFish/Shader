#include "/lib/world/debug.glsl"
#if WORLD_DEBUG_VIEW == 6 || WORLD_DEBUG_VIEW == 8 || WORLD_DEBUG_VIEW == 10
#include "/lib/world/point_lighting.glsl"
#include "/lib/world/gi.glsl"
#endif
uniform sampler2D colortex0;
uniform sampler2D colortex6;
uniform sampler2D colortex5;
#if WORLD_DEBUG_VIEW == 6 || WORLD_DEBUG_VIEW == 8 || WORLD_DEBUG_VIEW == 10
uniform sampler2D colortex4;
uniform sampler2D depthtex0;
uniform sampler2D shadowcolor0;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
#endif
uniform vec3 cameraPosition;
uniform float viewWidth;
uniform float viewHeight;
layout(location=0) out vec4 result;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
#if WORLD_DEBUG_VIEW == 0
    result = vec4(texture(colortex0, uv).rgb, 1.0);
#elif WORLD_DEBUG_VIEW == 5
    // Hit-face albedo and finite glass transmission expose the material path
    // used by lighting/reflections. Magenta indicates unresolved source data.
    vec4 material = texture(colortex5, uv);
    vec3 colour = material.a > 0.5 ? pow(max(material.rgb, vec3(0.0)), vec3(1.0 / 2.2))
        : texture(colortex0, uv).rgb;
    result = vec4(colour, 1.0);
#elif WORLD_DEBUG_VIEW == 6 || WORLD_DEBUG_VIEW == 8 || WORLD_DEBUG_VIEW == 10
    // Isolated direct-light preview; this is not the final lighting model.
    vec4 material = texture(colortex5, uv);
    float depth = texture(depthtex0, uv).r;
    vec3 colour = texture(colortex0, uv).rgb;
    if (depth < 1.0 && material.a > 0.5) {
        vec4 view = gbufferProjectionInverse * vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
        vec3 relative = (gbufferModelViewInverse * vec4(view.xyz / view.w, 1.0)).xyz;
        int face = int(round(texture(colortex4, uv).z));
        vec3 normal = vec3(0.0);
        normal[clamp(face / 2, 0, 2)] = face % 2 == 0 ? 1.0 : -1.0;
        float explained;
        vec3 direct = worldPointLightInfluence(colortex6, worldPosition(relative, cameraPosition), normal, explained);
        vec3 indirect = worldIndirectLight(colortex6, worldPosition(relative, cameraPosition), normal);
        colour = pow(max(material.rgb * (vec3(0.04) + direct * 3.0 + indirect), vec3(0.0)), vec3(1.0 / 2.2));
#if WORLD_DEBUG_VIEW == 10
        colour = pow(max(material.rgb * indirect, vec3(0.0)), vec3(1.0 / 2.2));
#endif
#if WORLD_DEBUG_VIEW == 8
        WorldPointLight light = worldReadPointLight(colortex6, 0);
        vec3 ray = vec3(worldPosition(relative, cameraPosition).block - light.position.block)
            + worldPosition(relative, cameraPosition).fraction - light.position.fraction;
        colour = worldShadowLightMapped(colortex6, 0, false)
            ? vec3(worldPointShadowVisibility(colortex6, 0, ray, light.radius, normal)) : vec3(1.0, 0.0, 1.0);
        if (uv.x > 0.7 && uv.y < 0.3) {
            WorldPosition owner = worldPosition(relative - normal * 0.002, cameraPosition);
            ivec3 cell = owner.block - worldReadOrigin(colortex6, false);
            vec4 status = texelFetch(shadowcolor0, worldCapturePixel(false, cell), 0);
            int code = status.b > 0.0 ? int(round(status.g / status.b)) : 0;
            colour = vec3(float(code & 1), float((code >> 1) & 1), float((code >> 2) & 1));
        }
#endif
    }
#if WORLD_DEBUG_VIEW == 8
    if (uv.x < 0.3 && uv.y < 0.3) {
        vec2 grid = uv / 0.3 * vec2(3.0, 2.0);
        int face = int(grid.x) + int(grid.y) * 3;
        ivec2 pixel = ivec2(face % 24, face / 24) * WORLD_POINT_SHADOW_SIDE
            + ivec2(fract(grid) * float(WORLD_POINT_SHADOW_SIDE));
        colour = vec3(texelFetch(colortex6, worldRegion(WORLD_REGION_POINT_SHADOWS).xy + pixel, 0).r);
    }
#endif
    result = vec4(colour, 1.0);
#else
    result = vec4(worldDebugView(colortex6, uv, cameraPosition, WORLD_DEBUG_VIEW), 1.0);
#endif
}
