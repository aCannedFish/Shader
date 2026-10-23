#include "/lib/world/debug.glsl"
#if WORLD_DEBUG_VIEW == 6
#include "/lib/world/point_lighting.glsl"
#endif
uniform sampler2D colortex0;
uniform sampler2D colortex6;
uniform sampler2D colortex5;
#if WORLD_DEBUG_VIEW == 6
uniform sampler2D colortex4;
uniform sampler2D depthtex0;
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
#elif WORLD_DEBUG_VIEW == 6
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
        colour = pow(max(material.rgb * (vec3(0.04) + direct * 3.0), vec3(0.0)), vec3(1.0 / 2.2));
    }
    result = vec4(colour, 1.0);
#else
    result = vec4(worldDebugView(colortex6, uv, cameraPosition, WORLD_DEBUG_VIEW), 1.0);
#endif
}
