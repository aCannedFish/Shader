# 来源

## 月面

`shaders/textures/sky-noise.png` 的月面区域由 NASA Scientific Visualization Studio 的 CGI Moon Kit 月球颜色图缩小为 512×256 后打包。原作者为 Ernie Wright，数据来自 Lunar Reconnaissance Orbiter 的 LROC。项目使用的原始文件为 `lroc_color_2k.jpg`，不对其宣称额外的科研精度。

- [CGI Moon Kit](https://svs.gsfc.nasa.gov/4720/)
- [原始文件](https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/lroc_color_2k.jpg)
- [NASA SVS 使用条件](https://svs.gsfc.nasa.gov/help/)

NASA SVS 说明未另行标注的内容属于公共领域，可下载、使用和再分发。月面数据按其来源条件使用，不作为项目原创 MIT 代码的一部分重新授权。项目与 NASA 不存在背书或合作关系。图集中的云噪声由项目程序确定性生成。

## 工具

离线预览在用户机器上下载并构建 [apitrace](https://github.com/apitrace/apitrace)，固定提交为 `706f9d61190684cb3e710fdf14c8f2a5ff13d9a3`。apitrace 的各组件许可见其仓库及文件头；项目发布包不分发其源码、二进制或本机捕获记录。

Python 工具按需使用 Pillow、NumPy；Shader 编译检查使用 glslang；Mod 编译引用用户已安装的 Forge、Minecraft、OptiFine 和 LWJGL。发布包不包含这些依赖的游戏或加载器文件。

## 接口

实现与配置参考以下接口及算法资料：

- [OptiFine Shader 接口](https://github.com/sp614x/optifine/blob/master/OptiFineDoc/doc/shaders.txt)
- [Minecraft Forge](https://github.com/MinecraftForge/MinecraftForge)
- [Filament 透射与吸收材质](https://google.github.io/filament/main/materials.html)
- [SIGGRAPH 2016 实时体积云](https://advances.realtimerendering.com/s2016/)

上述项目和资料维持各自的著作权与许可。本项目未将 Minecraft、OptiFine 或用户存档纳入源代码及发布包。
