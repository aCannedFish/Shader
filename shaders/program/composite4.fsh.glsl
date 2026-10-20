/* 水平泛光过滤。复用 alpha 的首个纹素，将太阳可见度传递到下一道过滤。 */
/* RENDERTARGETS: 4 */
#include "../lib/bloom.glsl"
uniform sampler2D colortex3;

void main() {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 uv = gl_FragCoord.xy / bloomSize();
    float visibility = 0.0;
    if (gl_FragCoord.x < 1.0 && gl_FragCoord.y < 1.0) {
        visibility = texture2D(colortex3, vec2(0.5) / size).a;
    }
    vec3 bloom = filterBloom(colortex3, uv, vec2(1.0, 0.0));
    gl_FragData[0] = vec4(bloom, visibility);
}
