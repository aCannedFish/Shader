# 兼容

## 基线

| 项目 | 0.1.4 状态 |
| --- | --- |
| Minecraft | Java Edition 1.21.11 |
| 加载器 | OptiFine HD U J9 |
| Forge | 61.0.8，配套 Mod 使用该版本编译并验证 |
| Java | 编译目标 21，实际运行验证为 Oracle/Homebrew Java 25 |
| 平台 | Apple M3、macOS、Apple OpenGL 4.1 |
| 场景 | 主世界；日夜、水面、水下、局部光照及植被固定场景 |

已验证组合不代表每一种硬件、世界、资源包或设置组合均已覆盖。

## 加载器

基础 Shader 采用 OptiFine 风格的程序名称、属性和 uniform。Iris/Sodium、Fabric 和其他 OptiFine 版本尚未完成专项验证，0.1.4 不承诺其兼容性。配套 Mod 为 Forge 客户端模块，直接使用 OptiFine 纹理和设置接口，不适用于 Iris 或 Fabric。

Forge 61.2.1 与 J9 混用时在本机出现过 `Gui.updateContextualInfo` 缺失和 `LootModifierManager` 未初始化的崩溃。使用 [OptiFine 官方列出的 Forge 61.0.8](https://optifine.net/downloads)。

## 图形接口

Shader 入口为 GLSL 120，实际程序由 OptiFine 进行兼容转换。局部阴影与 GI 使用 GLSL 330、浮点纹理、VAO、FBO 和普通光栅化。

管线使用最多八个颜色附件。Mod 额外使用纹理单元 13、14，天空噪声使用单元 15。不能依据源文件的 `#version 120` 推断整个系统能在旧 OpenGL 2.x 硬件上运行。当前确认的图形基线为 OpenGL 4.1；其他满足接口能力的平台仍需实测。

## 限制

- 日常离线预览工具目前支持并验证 Apple Silicon macOS。它需要先运行真实客户端采集场景，之后以相同渲染调用离线重放。
- 水面 SSR 和折射使用单层屏幕深度，视角外及遮挡后的几何无法完整重建；缺失反射使用天空回退。
- 默认 GI 与点光阴影为有限范围求解，边缘逐渐使用原版光照；范围外的火把不会各自拥有局部阴影图。
- 局部求解不包含活动实体、手持光源模型、植物贴图镂空和完整透明材质遮挡；风摆与日月阴影匹配，局部遮挡使用方块形状近似。
- GI 是漫反射体素近似，不包含无限反弹、镜面多次反弹或完整路径追踪。
- 主世界以外的维度、特殊天气、PBR 资源包、Distant Horizons 与其他渲染 Mod 尚未完成专项验证。

## 报告

提交 Issue 时提供光影与 Mod 版本、Minecraft/Forge/OptiFine/Java 版本、系统与 GPU、相关设置、时间天气、相机位置和复现步骤。附上去除账号凭证后的相关日志及实际画面；编译错误应包含首个错误和完整异常栈。
