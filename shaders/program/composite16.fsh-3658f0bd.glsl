#define SIMPLE_VARYING in
layout(location=0) out vec4 fullOut0;
layout(location=1) out vec4 fullOut1;
layout(location=2) out vec4 fullOut2;
layout(location=3) out vec4 fullOut3;
layout(location=4) out vec4 fullOut4;
/* J9 在帧开始重置翻转索引；成对写入让介质历史留在下一帧读取的纹理银行。 */
/* RENDERTARGETS: 13 */
/* 全局渲染设置。集中定义加载器常量、缓冲格式和可调宏；各程序共享同一组默认值。
 * 游戏内选项由 shaders.properties 分组，用户选择由加载器保存。
 */
#include "/settings.glsl"

uniform sampler2D colortex13;

void main() {
    fullOut0 = texture(colortex13, vec2(0.5));
}

