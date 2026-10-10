# 开发

## 目录

```text
shaders/       Shader 入口、设置、语言和纹理
companion/     Forge 客户端光照模块与 GPU 程序
tools/         编译、配置校验、打包、部署与预览
docs/          项目文档
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
python3 tools/check_glsl.py
python3 tools/configuration.py --check
```

GLSL 检查覆盖 40 个入口的语法和类型，不等同于驱动运行验证。配置检查覆盖页面参数、默认值、取值范围、语言文本、说明及生成文档一致性。

更改了默认值或参数说明后运行 `python3 tools/configuration.py`，再检查生成的 `docs/configuration.md` 和 `docs/configuration.json`。文档保留人工编写的调节建议，参数表由源码生成。

## 构建

```bash
python3 tools/build_companion.py \
  --instance /path/to/minecraft/versions/instance \
  --java-home /path/to/jdk
python3 tools/build_release.py
```

`--java-home` 可省略，脚本使用当前 PATH 的 `javac`。实例参数指向同时包含实例 JSON 和游戏 JAR 的已安装目录。构建复用该实例元数据中的依赖，不下载或分发游戏库。

Mod 的版本声明应与 `VERSION` 一致。打包器检查配置文档和 JAR 元数据，输出光影 ZIP、配置文档 ZIP、Mod JAR、发布说明和 SHA-256 校验文件。`--shader-only` 可只构建 Shader 与文档，用于不具备游戏依赖的 CI。

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

日常 `render` 和 `watch` 执行源码转换与 GPU 重放，不启动 Minecraft。输出位于 `.preview/latest/`。预览只包含当前捕获的镜头；专项检查需要先采集对应场景。

修改缓冲布局、渲染尺度、纹理资源、Shader 接口或 Mod 求解参数需要重新采集。普通 Shader 算法与颜色修改可以离线重放。UI 标签和页面布局不影响录制渲染状态。

## 约定

- 文档文件名使用英文单词和短横线；编号文档保留两位数字前缀。`README.md`、`CHANGELOG.md` 等通用文件沿用大写名称。
- GLSL 公共模块使用 include guard；模块注释说明输入、用途和实现约束。
- 算法使用线性颜色，显示编码统一在最终输出执行。
- 世界固定效果使用绝对世界坐标；视图和阴影变换遵守共享空间函数。
- 参数默认值集中于 `settings.glsl`，可选值写在对应宏的方括号注释中，界面分组位于 `shaders.properties`。
- Java 使用清晰的类与方法边界，GPU 更新在客户端线程执行，必须恢复被修改的 GL 状态。
- 不提交凭证、游戏依赖、存档、捕获记录、个人日志和构建产物。
- 提交前执行适合变更的检查，发布前核对 Shader、Mod、文档与版本一致性。

## 发布

更新 `VERSION`、Mod 元数据与 `CHANGELOG.md`，生成配置文档，完成编译和固定场景验证，再构建发布包。提交后创建 `v<版本>` 标签，并将 `dist/releases/<版本>/` 的安装文件、文档和校验文件附到 GitHub Release。

仓库 CI 执行 GLSL 与配置检查，并验证不含 Mod 的打包流程。实际驱动、Mod 和视觉验证在具备已验证游戏实例的环境完成。
