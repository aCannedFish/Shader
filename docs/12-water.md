# 水体

更新日期：2026-10-14。

## 光照

当地天光与不透明阴影贴图 `shadowtex1` 控制日月直射、高光及天空反射。方块光独立提供漫反射与散射辐射，封闭水域不叠加白天的天空亮度。日月镜面高光采用 GGX 与 Fresnel，并以独立强度控制。

## 透射

水面以透射为主。`deferred` 保存不透明 HDR 场景到 `colortex6`，水面在 `colortex5` 存储波浪法线、当地天光可见度与线性视图深度，在 `colortex7` 保存局部散射辐射和薄层密度。

水底颜色和深度始终在原屏幕坐标采样。视线上的水面位置与不透明几何位置共同确定水内光程，各颜色通道按吸收系数与浑浊度作指数衰减，少量当地散射保留水色。浅水薄层的不透明度随垂直水深下降。

水上视角已移除使水底显得更浅的折射位移，包括 Snell 射线求交、坐标夹取和屏幕边缘回退。波浪继续改变水面几何、法线与倒影，但不会移动水底图像或台阶轮廓。太阳入水方向仍用于聚光投影，与水底图像采样无关。

## 反射

在 `depthtex1` 上进行透视正确的屏幕空间 DDA，命中后读取不透明 HDR 颜色，并按粗糙度过滤。滤波允许背景进入倒影的轮廓，只排除明显更近的前景，避免深度拒绝把轮廓锁成锐利镜面。几何倒影排除水面下方的误命中。波浪法线控制倒影扭曲，Fresnel 控制观察角度变化。

默认粗糙度为 0.25，反射强度为 0.3。粗糙度还把部分清晰倒影过渡到当地散射，并降低日月高光的集中程度。水的法向反射率仍为约 2%；上述权重属于实时渲染的外观调节，没有改变水的折射率或改成完整的漫反射材质。

未命中或离屏时退回同一套天空与方块云。当地天光为零时，天空回退贡献为零。镜面倒影与透射、散射共同合成，再进入泛光和色调映射。

## 参数

水体选项集中在光影设置的水体页面。加载器中已检查按钮可选值与数值滑块；日常修改也可直接编辑 `settings.glsl` 后离线重放。

| 参数 | 默认值 | 作用 |
| --- | --- | --- |
| `ENABLE_WATER_TEXTURE` | 0 | 关闭表面动画纹理，保留透明度、染色与波浪 |
| `ENABLE_WATER_WAVES` | 1 | 顶点波动及逐像素波浪法线 |
| `WATER_SURFACE_OPACITY` | 0.06 | 水面薄层散射占比 |
| `WATER_TURBIDITY` | 0.035 | 随水深增加的浑浊程度 |
| `WATER_ABSORPTION` | 0.45 | 不同颜色通道的深度吸收 |
| `WATER_REFRACTION_STRENGTH` | 1.0 | 水下观察界面的轻微波动 |
| `WATER_COLOR_LIGHTNESS` | 0.5 | 水色浅淡程度，同时调整吸收色调 |
| `WATER_ROUGHNESS` | 0.25 | 高光宽度、倒影模糊与水下粗糙透射 |
| `WATER_REFLECTION_STRENGTH` | 0.3 | 倒影及日月镜面贡献的整体倍率 |
| `WATER_SPECULAR_STRENGTH` | 0.35 | 日月高光的独立倍率 |
| `WATER_REFLECTION_BRIGHTNESS` | 1.1 | 倒影辐射亮度，不给黑暗水域添加恒定颜色 |

## 管线

低密度水面不能被 alpha 测试整片剔除。程序关闭水面的加载器 alpha 测试，并保留几何信息输出；实际薄层密度单独写入光学附件，合成阶段再计算透射。完全透明的玻璃贴图像素仍在材质阶段显式丢弃，玻璃等非水材质不产生水波或水面光学标记。

水面辅助附件关闭混合并每帧清零。新增附件、材质映射或阶段设置时需重新采集。普通源码及数值修改可直接离线重放，不要求启动 Minecraft。

## 验证

固定镜头包含水面近景、立柱倒影、水波时间采样、封闭暗水池、火把水池、夜间水池及玻璃遮挡。专用 GPU 对照检查比较纹理、浑浊度、反射强度与无水介质的画面，检查水下波动开关不会改变水上看到的水底，并验证水面几何标记存在、封闭水域不受日月照明影响。

```bash
python3 tools/preview.py render --scene water --scene water_cave_lit
python3 tools/preview.py verify-materials
python3 tools/preview.py verify-water
```

移除视深折射之前的材质检查确认水面光学标记覆盖 474,100 个像素。与关闭水介质相比，默认水体的平均通道差为 28.28；开启纹理为 13.50、关闭折射为 3.35、将倒影强度调到 1.0 为 6.98、将浑浊度调到 0.10 为 7.01。三个封闭水池关闭日月光照后的水面差异均为 0。数值为实际显示图的 0–255 通道差。倒影时间采样的平均通道差为 5.25，关闭波浪后的静止对照为 0.17；粗糙度从 0.04 调到 0.35 后，倒影边缘能量从 3.97 降至 3.79。

结果保存在 `.preview/material-verification/` 和 `.preview/water-verification/`。预览器会以采集时的不可变源码验证捕获基准，再以当前源码作画面对照。

## 来源

- McGuire, M. 与 Mara, M.（2014），[Efficient GPU Screen-Space Ray Tracing](https://jcgt.org/published/0003/04/04/paper.pdf)，JCGT 3(4)：屏幕空间 DDA。
- [Filament 材质模型](https://google.github.io/filament/main/filament.html)与[透射材质](https://google.github.io/filament/main/materials.html)：GGX、Fresnel、折射率与按光程计算的吸收。
- Iris 的 [DepthTex](https://shaders.properties/current/reference/buffers/depthtex/)、[ShadowTex](https://shaders.properties/current/reference/buffers/shadowtex/) 与 [deferred](https://shaders.properties/current/reference/programs/deferred/)：不透明深度与阶段时序。
- [OptiFine 配置说明](https://github.com/sp614x/optifine/blob/master/OptiFineDoc/doc/shaders.properties)：alpha 测试、附件混合与滑块。

水下光程、轻微波动和水上景物可见度见 [水下](15-underwater.md)，柔和聚光与日照光柱见 [水体改进](20-water-effects.md)。
