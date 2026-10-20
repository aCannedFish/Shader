
/*
 * gbuffers_clouds.vsh：禁用原版云网格。
 * 方块云由 composite 绘制；将原版云顶点放到裁剪范围之外，防止
 * 游戏的云选项覆盖 clouds=off 后重复绘制或写入错误的深度。
 */
void main() {
    gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
}
