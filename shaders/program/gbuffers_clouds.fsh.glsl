
/*
 * gbuffers_clouds.fsh：原版云网格不输出颜色或深度。
 * 自定义半透明方块云在 composite 合成，避免两套云叠加。
 */
void main() {
    discard;
}
