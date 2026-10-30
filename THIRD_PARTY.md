# 来源

## 月面

`shaders/textures/sky-noise.png` 的月面区域由 NASA Scientific Visualization Studio 的 CGI Moon Kit 月球颜色图缩小为 512×256 后打包。原作者为 Ernie Wright，数据来自 Lunar Reconnaissance Orbiter 的 LROC。项目使用的原始文件为 `lroc_color_2k.jpg`，不对其宣称额外的科研精度。

- [CGI Moon Kit](https://svs.gsfc.nasa.gov/4720/)
- [原始文件](https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/lroc_color_2k.jpg)
- [NASA SVS 使用条件](https://svs.gsfc.nasa.gov/help/)

NASA SVS 说明未另行标注的内容属于公共领域，可下载、使用和再分发。月面数据按其来源条件使用，不作为项目原创 MIT 代码的一部分重新授权。项目与 NASA 不存在背书或合作关系。图集中的云噪声由项目程序确定性生成。

## 接口

实现与配置参考以下接口及算法资料：

- [OptiFine Shader 接口](https://github.com/sp614x/optifine/blob/master/OptiFineDoc/doc/shaders.txt)
- [LabPBR 1.3 材质标准](https://github.com/shaderLABS/LabPBR/wiki)
- [Filament 透射与吸收材质](https://google.github.io/filament/main/materials.html)
- [SIGGRAPH 2016 实时体积云](https://advances.realtimerendering.com/s2016/)
- [Narkowicz 的 ACES 曲线拟合](https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/)：保留其简化拟合系数，仅映射亮度并加入本项目的色域约束。原作者允许按 CC0 或 MIT 使用该拟合。

上述项目和资料维持各自的著作权与许可。本项目未将 Minecraft、OptiFine 或用户存档纳入源代码及发布包。
