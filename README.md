# SimpleShader

面向 Windows 的 Minecraft Java 光影包，提供日月天空、体积云与云影、材质和水面反射、水下光学、天气与积水、植被风摆、矿物发光及显示处理。当前分支使用常规阴影、屏幕反射和可选 GPU 彩色传播，不需要配套世界数据 Mod。

运行组合为 Minecraft 1.21.11、OptiFine J9、OpenGL 4.5。主验收设备是 Core Ultra 7 155H、32GB DDR5 和 RTX 4060 Laptop。Low、Mid、High、Ultra 四档与彩色光照开关在同一包中提供；默认 Low，彩色关闭。

## 使用

安装、预设预算、效果取舍与构建方法见 [Windows 运行说明](docs/windows-playable.md)。当前开发计划与状态见 [PLAN.md](PLAN.md) 和 [状态记录](docs/migration/state.json)。本机性能、源码对照和问题定位见 [重构记录](docs/migration/redesign.md)。

从源码生成完整光影目录：

```powershell
python -X utf8 -m tools.preview.conventional --target .build/SimpleShader/shaders --preset LOW
```

生成目录可在游戏中切换全部预设和独立彩色开关。根目录的共享 `shaders/` 需经构建器装配。检查点安装前备份旧包和旧选项，并记录最终文件树哈希；测试助手不会安装到实际游戏实例。

当前主线已经合入 Windows 无 Mod 版本。`python -X utf8 tools/build_release.py --shader-only` 会装配当前渲染器后生成 ZIP；旧配套 Mod 和直接复制共享源码的部署入口已移除。迁移过程中的改进、对照代码和验证记录继续保留。

## 实现

日月光使用二维阴影。方块光保留游戏的传播与遮挡，彩色模式增加有界 RGB 体积。局部间接光以环境光、AO 和传播近似替代旧的逐灯阴影与多跳方向场。材质与水反射采用有界 SSR 和环境回退，屏外与遮挡背面使用近似。

研究了本机 Derivative、Photon、Complementary Reimagined 与 Rethinking Voxels 的资源和预算组织，独立编写本项目实现。第三方源码不包含在产物中。

## 历史

旧 0.2.4 发布版与配套 Mod 说明保存在 [历史文档](docs/legacy-0.2.4.md)。旧 macOS 编译或截图记录不作为 Windows 验收证据。

## 许可

项目代码采用 [MIT License](LICENSE)。月面数据与外部工具来源见 [THIRD_PARTY.md](THIRD_PARTY.md)。光影包不包含 Minecraft、Forge、OptiFine 或用户存档。
