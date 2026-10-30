#define SIMPLE_VARYING in
layout(location=0) out vec4 fullOut0;
layout(location=1) out vec4 fullOut1;
layout(location=2) out vec4 fullOut2;
layout(location=3) out vec4 fullOut3;
layout(location=4) out vec4 fullOut4;

/*
 * gbuffers_clouds.fsh：原版云网格不输出颜色或深度。
 * 自定义半透明方块云在 composite 合成，避免两套云叠加。
 */
void main() {
    discard;
}

