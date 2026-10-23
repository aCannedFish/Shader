#include "/lib/world/debug.glsl"
uniform sampler2D colortex0;
uniform sampler2D colortex6;
uniform vec3 cameraPosition;
uniform float viewWidth;
uniform float viewHeight;
layout(location=0) out vec4 result;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
#if WORLD_DEBUG_VIEW == 0
    result = vec4(texture(colortex0, uv).rgb, 1.0);
#else
    result = vec4(worldDebugView(colortex6, uv, cameraPosition, WORLD_DEBUG_VIEW), 1.0);
#endif
}
