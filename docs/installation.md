# 安装

当前 main 安装与构建方式见 [Windows 运行说明](windows-playable.md)。它使用当前独立光影包，不需要 SimpleShaderLighting Mod。以下 0.2.x 的 ZIP/JAR 安装步骤仅供恢复历史版本，不适用于当前主线。

## 版本

0.2.4 使用 Minecraft Java Edition 1.21.11、OptiFine HD U J9 和 Forge 61.0.8。Forge 用于配套 Mod。J9 对应的 Forge 版本可在 [OptiFine 下载页](https://optifine.net/downloads)核对；不要用其他 Forge 版本代替已验证组合。

游戏需要兼容的 Java 运行环境；Minecraft 1.21.11 的版本元数据要求 Java 21，当前项目的实际验证使用 Java 25。配套 Mod 编译目标为 Java 21。图形接口与平台状态见[兼容说明](compatibility.md)。

## 文件

从项目 [Releases](https://github.com/aCannedFish/Shader/releases) 下载光影 ZIP。彩色方块光、独立点光阴影、GI 与真实水深数据另需 `SimpleShaderLighting-0.2.4.jar`。

```text
游戏实例/
├── shaderpacks/
│   └── SimpleShader-0.2.4.zip
└── mods/
    └── SimpleShaderLighting-0.2.4.jar
```

ZIP 内必须直接包含 `shaders/`。下载的 GitHub Source code 压缩包有额外项目目录，不能直接作为光影安装。

## 步骤

1. 在启动器中建立 Minecraft 1.21.11 实例，安装 Forge 61.0.8 与 OptiFine HD U J9。
2. 使用启动器的“打开游戏目录”或游戏光影界面的“光影文件夹”定位当前实例目录。
3. 将光影 ZIP 放入该目录的 `shaderpacks/`。
4. 将可选 Mod JAR 放入同一目录的 `mods/`。本版原生水深与水面天光需要同版 Mod；升级时同时更新 Shader 和 Mod。
5. 启动游戏，在“选项 → 视频设置 → 光影”选择 SimpleShader，再进入“光影设置”。
6. 保持光影包文件名以 `SimpleShader` 开头，配套 Mod 用该前缀识别目标光影。

只安装 Shader 时，水体、天空、植被、日月阴影及原版方块光仍然可用。彩色方块光、独立点光阴影与 GI 需要配套 Mod；日月光的玻璃滤色由 Shader 实现。Mod 在客户端采集已经加载的附近方块，不改变服务器方块或正式存档。

## 隔离

开启版本隔离的启动器通常把 `shaderpacks/` 和 `mods/` 放在 `versions/<实例名>/`。以启动器打开的当前实例目录为准。

Minecraft Launcher 常见游戏根目录为 Windows 的 `%APPDATA%/.minecraft`、macOS 的 `~/Library/Application Support/minecraft` 和 Linux 的 `~/.minecraft`。这些是默认位置，自定义目录及版本隔离会改变实际位置。不要仅凭系统默认路径安装。

## 升级

更换光影 ZIP 后，在游戏中重新选择光影或按 F3 + R 重载。更换 Forge、OptiFine 或配套 Mod 后，需要完全退出并重新启动游戏。

替换配套 Mod 时先从 `mods/` 移除旧版 JAR，避免同时加载两个相同 Mod ID。本版包含雨天日月 GI 响应与遮挡复用更新，应同时安装 0.2.4 Shader ZIP 和 Mod JAR。0.2.3 Mod 可提供原生水深，但缺少本轮雨天 GI 调整；0.2.2 及更早版本的水下使用屏幕探针回退；0.1.x 的光照数据布局不兼容，会触发原版光照回退。

升级前保留原来的光影包及同名 `.txt` 设置文件。OptiFine 将用户选择保存在光影包对应的设置文件中，游戏内调参不会直接改写仓库的 `settings.glsl`。需要恢复当前版本默认值时，先使用设置界面的重置功能；手工处理设置文件前关闭游戏并备份。

主页面提供四档画质预设，中档对应默认值；默认反射为 32 步并使用云环境缓存。彩色光照默认开启，本版完整的 110 项设置和预设数值见[配置说明](configuration.md)。

地表雾缓存、矿物遮罩、非主世界的日月 GI 修正以及原生水深由配套 Mod 提供；相关数据需要“配套光照系统”开启。0.2.4 默认关闭模拟焦散，可在水体页面单独开启。

## 排错

| 现象 | 检查与处理 |
| --- | --- |
| 光影列表没有 SimpleShader | 确认当前实例目录及 ZIP 顶层 `shaders/` 结构 |
| 启动或加载世界时退出 | 先核对 Forge 61.0.8、OptiFine J9 和 Minecraft 1.21.11；查看 `crash-reports/` 及 `logs/latest.log` |
| 光影加载失败 | 查找 `[Shaders]` 和编译错误，报告首个错误及对应程序 |
| 没有独立火把阴影 | 检查 Mod JAR、光影名前缀、“配套光照系统”和“独立光源阴影”开关，以及活动范围和数量上限 |
| 间接光变化较慢 | 增加每帧传播预算或阴影更新数；高反弹次数和大体积需要更多收敛时间 |
| 夜晚过暗 | 先检查基础环境亮度，再调整夜间环境亮度、月光强度和夜间曝光；封闭洞穴也保留基础可见度 |
| 水面过亮或像塑料 | 优先降低水面反射强度与日月高光强度，适量调整浑浊度和散射不透明度 |
| 水下视距过短 | 调低水下密度、浑浊度或吸收强度，并保留深水最低能见度 |
| 性能开销过高 | 按[配置说明](configuration.md)先降低云质量、活动光源数、阴影分辨率及 GI 体积 |

Mod 日志的正常标记包括 `SIMPLE_LIGHTING companion loaded`、`GPU resources` 和 `GI published`。数据未完成时会使用原版光照回退；若出现 `disabled after error`，保留完整异常栈提交 Issue。

## 校验

在发布文件所在目录运行：

```bash
# macOS
shasum -a 256 -c SHA256SUMS.txt
# Linux
sha256sum -c SHA256SUMS.txt
```

Windows 可用 PowerShell 的 `Get-FileHash 文件名 -Algorithm SHA256` 与校验文件逐项核对。
