# SimpleShader

SimpleShader 是一个 Minecraft Java Edition 光影包，提供体积云、日月天空、水面反射与折射、清晰的水下视野、植被风摆，以及可选的独立点光阴影和多次漫反射全局光照。

当前版本为 0.1.2，主要针对主世界。已验证的运行组合为 Minecraft 1.21.11、OptiFine HD U J9、Forge 61.0.8；验证平台为 Apple M3、macOS 和 OpenGL 4.1。其他加载器、系统及维度的状态见[兼容说明](docs/compatibility.md)。

## 下载

从 [Releases](https://github.com/aCannedFish/Shader/releases) 下载：

| 文件 | 用途 |
| --- | --- |
| `SimpleShader-0.1.2.zip` | 光影包，直接放入游戏实例的 `shaderpacks/` |
| `SimpleShaderLighting-0.1.2.jar` | 可选 Forge Mod，启用独立点光阴影与多次漫反射 GI |
| `SHA256SUMS.txt` | 发布文件的 SHA-256 校验值 |
| `manifest.json` | 版本、源码提交、文件哈希与验证环境 |

GitHub 自动生成的 Source code 压缩包用于获取源码。安装光影时使用上表中的光影 ZIP。

## 功能

- 天空：Rayleigh/Mie 大气散射近似、日出日落、星空、圆形太阳及带月相的月球；月面采用 NASA LRO/LROC 数据。
- 云层：程序化体积云、参差的云底与云顶、风向移动、云层自遮挡与地面云影。
- 水面：波浪、可关闭纹理、深度吸收与浑浊度、屏幕反射、天空回退和可调日月高光。
- 水下：折射、内反射、按光程衰减、深水附近能见度下限、水底光源，以及近景轮廓连续处理；水下空间模糊已移除。
- 光照：日月直射、天光、方块光独立合成；夜间环境亮度与曝光可调。
- 局部光照：配套 Mod 为玩家附近的发光方块生成六面独立阴影图，并以有遮挡的体素辐射场求解有限次漫反射。
- 植被与后处理：树叶、草木和庄稼风摆，同步阴影；HDR、泛光、色调映射、曝光、饱和度、暗角及抖动。

## 安装

1. 准备 Minecraft 1.21.11 和 OptiFine HD U J9。需要配套光照时使用 Forge 61.0.8。
2. 将 `SimpleShader-0.1.2.zip` 放入启动器当前实例的 `shaderpacks/`，在游戏的光影界面选择该文件。
3. 需要独立点光阴影和 GI 时，将 `SimpleShaderLighting-0.1.2.jar` 放入同一实例的 `mods/`，完全退出并重新启动游戏。
4. 在光影设置中调整参数。无 Mod 或其数据未准备好时，局部光照自动使用原版光照场。

完整步骤、版本隔离、升级与故障排查见[安装说明](docs/installation.md)。

## 配置

设置按阴影、光照、世界、水体、植被、后处理与调试分组；光照包含局部阴影和 GI 子页面，世界包含天空和云层子页面。界面提供简体中文与英文。

全部界面参数的默认值、可选值、含义、性能建议和常见效果调节见[配置说明](docs/configuration.md)。默认值来源为 `shaders/settings.glsl`。配置文档通过脚本与源码保持一致。

## 实现

Shader 使用 OptiFine 程序接口与 GLSL 120 源码，经加载器转换后执行。配套 Mod 使用普通 GPU 光栅化和 GLSL 330，提供局部场景数据与两个光照纹理；当前实现不依赖计算着色器或硬件光线追踪。

水面反射与折射受单层屏幕深度的覆盖范围限制。GI 是有限范围、有限分辨率的漫反射近似，默认覆盖边长 32 方块的体积、最多 32 个活动点光源及 3 次反弹。活动实体、植物贴图镂空、完整透明遮挡和镜面多次反弹尚未纳入局部求解。

管线、缓冲布局、算法与实现边界见[实现说明](docs/architecture.md)。

本轮水体开销、软阴影、自阴影处理、实测记录与参考包差距见[优化记录](docs/18-optimization.md)。

村庄夜景的光照衰减、线性暖光和整体色彩校准见[光照调色](docs/19-lighting-color.md)。

浅水折射、柔和水下聚光与日照光柱见[水体改进](docs/20-water-effects.md)。

## 开发

```bash
python3 tools/check_glsl.py
python3 tools/configuration.py --check
python3 tools/build_companion.py --instance /path/to/minecraft/versions/instance
python3 tools/build_release.py
```

`shaders/` 为光影本体，`companion/` 为配套 Mod，`tools/` 包含检查、打包、部署和离线 GPU 预览工具。当前包含 42 个着色器入口，水下与局部光照通过固定场景验证。

构建依赖、编码约定、离线预览和发布流程见[开发说明](docs/development.md)。

## 许可

项目代码采用 [MIT License](LICENSE)。月面数据与外部工具的来源、使用条件及分发范围见[来源说明](THIRD_PARTY.md)。发布包不包含 Minecraft、Forge、OptiFine 或用户存档。
