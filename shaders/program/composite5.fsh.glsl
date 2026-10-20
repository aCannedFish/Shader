/* 垂直泛光过滤，复用已经用完的亮部附件；首个 alpha 继续保留太阳可见度。 */
/* RENDERTARGETS: 3 */
#include "../lib/bloom.glsl"
uniform sampler2D colortex4;

void main() {
    vec2 size = vec2(viewWidth, viewHeight);
    vec2 uv = gl_FragCoord.xy / bloomSize();
    float visibility = 0.0;
    if (gl_FragCoord.x < 1.0 && gl_FragCoord.y < 1.0) {
        visibility = texture2D(colortex4, vec2(0.5) / size).a;
    }
    gl_FragData[0] = vec4(filterBloom(colortex4, uv, vec2(0.0, 1.0)), visibility);
}
