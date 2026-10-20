# 开发

## 目录

```text
shaders/       三个维度的入口、共享程序、设置、语言和纹理
companion/     Forge 客户端光照模块与 GPU 程序
tools/         编译、配置校验、打包、部署与预览
docs/          项目文档
.vscode/       编辑器工作区配置
VERSION        当前项目版本
CHANGELOG.md   版本变化
dist/          本地生成的发布产物，不纳入 Git
```

## 依赖

基础检查与光影打包需要 Python 3.10 及以上、Git、glslang。Mod 构建另需 JDK 21 及以上、已安装的 Minecraft 1.21.11 / Forge 61.0.8 / OptiFine J9 实例。当前验证 JDK 为 25。

```bash
# macOS
brew install glslang
# Ubuntu
sudo apt-get install glslang-tools
```

天空纹理已经随源码分发，普通构建无需重建。重新生成纹理时另装 NumPy 和 Pillow，然后运行 `python3 tools/build_sky_assets.py`；可用 `--moon` 指向已缓存的 NASA 原图。

## 检查

```bash
python3 tools/check_repository.py
python3 tools/check_glsl.py
python3 tools/configuration.py --check
```

GLSL 检查覆盖三个维度共 132 个入口的语法和类型，不等同于驱动运行验证。配置检查覆盖页面参数、默认值、取值范围、语言文本、说明及生成文档一致性。

更改了默认值或参数说明后运行 `python3 tools/configuration.py`，再检查生成的 `docs/configuration.md` 和 `docs/configuration.json`。文档保留人工编写的调节建议，参数表由源码生成。

macOS 可单独检查泛光的实际 GPU 计算，覆盖边界、奇数视口、色相和亮部能量：

```bash
.preview/venv/bin/python -m pip install numpy Pillow
python3 tools/check_bloom.py
```

该命令不启动 Minecraft。`--baseline-shaders /path/to/old/shaders` 可测量旧两道泛光与当前实现的 GPU 工作量；输出在 `.preview/bloom-verification/`，计时不代表整帧性能。植被透光固定镜头为 `foliage_backlit`、`foliage_frontlit` 和 `foliage_night`，其中逆光场景同时含无遮挡薄叶和背后有实体墙的薄叶。

Mod 的网格分配和动态更新回归使用 `tools/check_companion_performance.py` 及 `perf_static`、`perf_walk`、`perf_edits` 原生场景，命令和测量限制见[性能说明](performance.md)。此类 Mod 调度修改必须启动真实客户端；固定 GPU 调用重放不能检验 Java 缓存失效和任务调度。

天空缓存与体积质量还可单独检查：

```bash
python3 tools/check_sky_cache.py
python3 tools/check_volume_quality.py
python3 tools/check_atmosphere.py
python3 tools/check_ore_glow.py
```

前者检查实际查找函数的周期边界与区域隔离，后者在同一上下文交替测量相同云积分的两档视口。这些探针均不启动游戏；氛围探针检查地形缓存重建、雾透射、光学合并、极光运动和时钟回绕，矿物探针检查十八种遮罩的字节解码、UV 精度、石头像素零发光及关闭回退。计时仅覆盖独立云积分，不代表游戏帧率。

## 构建

```bash
python3 tools/build_companion.py \
  --instance /path/to/minecraft/versions/instance \
  --java-home /path/to/jdk
python3 tools/build_release.py
```

`--java-home` 可省略，脚本使用当前 PATH 的 `javac`。实例参数指向同时包含实例 JSON 和游戏 JAR 的已安装目录。构建复用该实例元数据中的依赖，不下载或分发游戏库。

Mod 的版本声明应与 `VERSION` 一致。打包器检查配置文档和 JAR 元数据，输出光影 ZIP、Mod JAR、发布说明、清单和 SHA-256 校验文件。`--shader-only` 只构建光影 ZIP，用于不具备游戏依赖的 CI。

## 部署

```bash
bash tools/deploy.sh /path/to/game-instance
```

该命令把 `shaders/` 同步为 `<实例>/shaderpacks/SimpleShader/shaders/`。不指定目录时使用本机 `~/minecraft` 的既有根目录和版本隔离实例。脚本只接受已有游戏目录。

Shader 改动可用 F3 + R 重载。Mod 改动需要重新构建、替换实例 `mods/` 中的 JAR 并重新启动游戏。

## 预览

离线预览的捕获与重放目前针对 Apple Silicon macOS。准备阶段依赖 Xcode Command Line Tools、CMake、Ninja、Python 和已安装的游戏；安装工具：

```bash
brew install cmake ninja glslang
python3 tools/preview.py setup
python3 tools/preview.py probe
python3 tools/preview.py capture \
  --instance /path/to/minecraft/versions/instance \
  --world 'World Name' \
  --java-home /path/to/jdk \
  --scene underwater_shallow --scene underwater_deep \
  --scene underwater_air --scene underwater_air_deep \
  --scene underwater_interface
```

`capture` 在 `.preview/game/` 中复制指定存档，生成测试几何，自动调整镜头并采集真实 GPU 调用。正式存档不接受测试命令。重新采集使用 `--refresh`，旧数据移入 `.preview/archive/`。

日常修改后运行：

```bash
python3 tools/preview.py render
python3 tools/preview.py watch
python3 tools/preview.py verify-underwater
```

日常 `render` 和 `watch` 执行源码转换与 GPU 重放，不启动 Minecraft。输出位于 `.preview/latest/`。预览只包含当前捕获的镜头；专项检查需要先采集对应场景。日光散射可使用 `air_forest_low` 等固定镜头，并运行 `python3 tools/preview.py verify-air` 检查。

修改缓冲布局、渲染尺度、泛光分辨率、体积场分辨率、纹理资源、Shader 接口或 Mod 求解参数需要重新采集。普通 Shader 算法与颜色修改可以离线重放。UI 标签和页面布局不影响录制渲染状态。

复现玩家截图时，可以显式设置采集窗口、视距和准备好的参数变体：

```bash
python3 tools/preview.py capture --refresh --world '新的世界 (1)' \
  --width 1710 --height 976 --render-distance 12 \
  --shader-dir .preview/shadow-beads-final-shaders --scene shadow_path_photo
```

宽高为系统逻辑窗口尺寸，Retina 显示下实际录制像素可能为其两倍；最终尺寸以录制清单为准。参数变体由独立 Shader 目录提供，源游戏选项与存档不会被修改。采集器会重新放置大窗口，避免 macOS 初始布局缩小窗口，导致原生截图与 GPU 重放尺寸不一致。

## 编辑器

`.vscode/settings.json` 配置 GLSL IntelliSense（`pablodegroot.glsl-intellisense`）：把 `shaders/` 加入包含搜索路径，排除 `.check/` 与 `.preview/` 中的展开副本，声明 OptiFine 的缓冲格式常量，使 glslangValidator 能解析本包源码。`.vscode/extensions.json` 只推荐该插件，其余 GLSL 插件会重复报诊断或争抢 `glsl` 语法高亮。这两份文件在 `.gitignore` 中单独放行。

包内 `#include` 统一写相对当前文件的路径，引用上级目录写 `../settings.glsl` 这种形式，因此依赖解析、跨文件跳转与编译器检查都可用，`glslLsp.diagnostics.undeclared` 与 `glslLsp.diagnostics.glslang.enable` 保持打开。

## 约定

- 文档文件名使用英文单词和短横线。`README.md`、`CHANGELOG.md` 等通用文件沿用大写名称。
- GLSL 公共模块使用 include guard；模块注释说明输入、用途和实现约束。`#include` 写相对当前文件的路径，不用以 `/` 开头的光影包根路径写法。
- 算法使用线性颜色，显示编码统一在最终输出执行。
- 世界固定效果使用绝对世界坐标；视图和阴影变换遵守共享空间函数。
- 参数默认值集中于 `settings.glsl`，可选值写在对应宏的方括号注释中，界面分组位于 `shaders.properties`。
- Java 使用清晰的类与方法边界，GPU 更新在客户端线程执行，必须恢复被修改的 GL 状态。
- 不提交凭证、游戏依赖、存档、捕获记录、个人日志和构建产物。
- 提交前执行适合变更的检查，发布前核对 Shader、Mod、文档与版本一致性。

## 发布

更新 `VERSION`、Mod 元数据与 `CHANGELOG.md`，生成配置文档，完成编译和固定场景验证，再构建发布包。提交后创建 `v<版本>` 标签，并将 `dist/releases/<版本>/` 的光影 ZIP、Mod JAR、清单与校验文件附到 GitHub Release。

Release 标题使用 `SimpleShader <版本>`，正文沿用最近版本的简短概述、变更列表、兼容与升级提示，再列出已验证环境、四个发布附件和对应标签下的文档链接。正文不重复标题和发布日期，不单独上传文档压缩包。更改默认配置时，以当前选中光影包的有效设置为准，将保存的覆盖值写入源码，并在发布说明中列明；不得把个人设置文件随包分发。

仓库 CI 执行 GLSL 与配置检查，并验证不含 Mod 的打包流程。实际驱动、Mod 和视觉验证在具备已验证游戏实例的环境完成。

入口文件仅保留版本、维度宏和共享实现引用；实际代码位于 `shaders/program/`，公共模块位于 `shaders/lib/`。修改程序体时编辑共享文件，三个维度同时生效。材质与维度的固定镜头为 `material_day`、`material_night`、`material_glass`、`nether_materials`、`nether_night`、`end_materials`、`end_night`，均在隔离存档副本中生成。

材质与维度的离屏约束检查运行 `python3 tools/check_materials.py`，覆盖完整法线半球、RGBA8 材质存储、GGX 互易性、背光截止、Fresnel 掠射极限，以及非主世界的日月和云层隔离。此检查使用 macOS OpenGL，不启动 Minecraft。

反射交点检查运行 `python3 tools/check_ssr.py`，直接调用生产 GLSL，覆盖不透明、透明与水面路径的同平面自命中、深度断层、细小轮廓、朝向或背离相机的真实交点，以及 1920×1080 和 24 位深度下连续表面的命中覆盖率。`--baseline-reflection /path/to/material_reflection.glsl` 可在相同解析深度场中比较旧实现；输出位于 `.preview/ssr-verification/`。游戏内固定镜头 `reflect_wall` 和 `reflect_wall_glass` 使用相同相机观察石英外墙、台阶和植被，后者额外加入交叠玻璃，供原生截图复核。

氛围与矿物的固定镜头包括 `atmos_forest_dawn`、`atmos_forest_noon`、`atmos_mountain`、`atmos_aurora_north`、`atmos_aurora_rain`、`nether_atmosphere`、`end_atmosphere`、`end_void`、`ore_glow_gallery` 和 `ore_glow_closeup`。捕获助手在世界副本中建立地形和封闭矿石暗室，并读取实际 GPU 地表缓存与矿物遮罩校验上传。修改图集布局、方块映射或配套 Mod 数据后需重新捕获；固定帧无法提供旧记录中不存在的新数据。
