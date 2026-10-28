/* J9 在帧开始重置翻转索引；成对写入让介质历史留在下一帧读取的纹理银行。 */
/* RENDERTARGETS: 13 */
#include "../settings.glsl"
uniform sampler2D colortex13;

void main() {
    gl_FragData[0] = texture2D(colortex13, vec2(0.5));
}
