# Windows接手

目标为Windows、Ultra 7 155H、32GB DDR5、RTX4060 Laptop。低档约60 FPS；效果补齐后系统优化，当前先修稳定性和实现错误。12阶段49包继续保留。

## 本机证据

实际实例为 `F:\Minecraft\.minecraft`，HMCL位于 `D:\Apps\HMCL-3.17.0.361.exe`。最近用户运行日志确认Minecraft1.21.11、Forge61.0.8、OptiFine J9 pre2、Microsoft Java21.0.7、RTX4060 Laptop及NVIDIA610.74。该运行加载了SimpleShaderLighting0.2.4，有OpenGL1282及配套光照计算日志；不能作为无Mod目标验收。

原日志和设置保存于 `local-docs/migration/windows/intake/`。2026-10-25-1日志结束于着色器加载期间，没有提供明确崩溃堆栈；现阶段不认定OOM或驱动崩溃根因。

## 编译故障

`.preview/captures-windows-baseline/capture.log` 记录无配套Mod隔离运行：Intel Arc，GL3.3上下文；142个阶段因GLSL保留字 `resource` 编译失败，并触发链接失败和1282。源码统一将相应采样器参数改为 `staticData`。此项证据属于Intel驱动，不能标记RTX通过；原用户RTX日志没有这项编译错误。

`tools/check_glsl.py` 原来只替换正斜杠，Windows维度入口产生未创建的输出子目录，现使用Path.as_posix规范化后展开。检查使用官方Khronos glslang16.6.0。

## 原生复测

`tools/preview/minecraft.py` 已按本机库规则选择Windows依赖与natives，使用javaw.exe，不加载CGL包装器。源存档只复制后使用；助手只建场景、固定相机与读回，不上传运行时世界数据。Windows恢复Forge默认早期OpenGL初始化，Mac遗留关闭设置只留在历史路径。

每次运行必须从日志确认renderer、实际包、无配套Mod及编译链接结果，再判断画面和帧时间。`windows-baseline` 与 `windows-javaw` 均选中Intel，后者只用于验证编译修复，不纳入RTX性能验收。`--prefer-discrete-gpu` 临时设置精确Java路径的Windows高性能GPU偏好，进程退出后恢复原值；后续三个RTX运行均确认NVIDIA renderer，退出后该临时值已移除。

## 尺寸故障

`windows-rtx-settings` 使用用户原设置，原生读回两张阴影附件均为2419×2419，而生成布局要求2688×2688。J9二进制的resizeShadow明确将Shader声明尺寸乘configShadowResMul，当前值为0.9。几何阶段按固定布局光栅化整数记录，prepare按未缩放地址读取，因而读取错位且部分越界。这不是阴影清晰度变化，固定数据采集合同已被破坏。

`windows-rtx-shadow-unit` 只将隔离设置的shadowResMul改为1.0，实际两附件均2688×2688；相同房间恢复GPU点光高光。两次运行完整加载，无编译、链接、1282或助手失败日志。当前迁移候选安装要求阴影质量倍率1.0；后续固定数据采集与可缩放太阳阴影的解耦仍需处理，不能宣称任意阴影倍率均受支持。屏幕渲染倍率与此独立。

## 性能证据

两次均为RTX4060 Laptop/NVIDIA610.74、输出1280×720、内部960×540、视距12、限帧120且throttle_reason=NONE，无配套Mod。设备接电、系统平衡电源方案。密集光源perf_static并非最终各场景性能验收。

| 阴影倍率 | 测量秒数 | 帧样本 | FPS | P50 ms | P95 ms | P99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.9，尺寸错误 | 18.115 | 126 | 7.011 | 142.656 | 167.554 | 191.317 |
| 1.0，尺寸正确 | 18.149 | 95 | 5.289 | 185.476 | 200.595 | 820.373 |

0.9的较高帧率伴随数据和光照缺失，不能视为优化。正确设置下约5FPS已复现。首次原生加载记录显示多个编译/链接程序之间存在数秒至数十秒间隔，整包编译约数分钟；这能解释本次长加载的一部分，尚不能解释用户此前那次崩溃。没有复现原生崩溃或取得对应堆栈。

## 检查点

WIN-BOOTSTRAP保存Windows标识符修复、路径检查、正常启动及正确尺寸配置。Khronos glslang16.6.0在Windows检查609阶段、303/303链接通过；RTX本机两场景输出完成，源码效果类别未删减。部署使用完整 `.preview/windows-reserved-fix/shaders`，倍率1.0；旧Shader、原选项及SimpleShaderLighting0.2.4保留到实例外层备份目录。部署清单见 `local-docs/migration/checkpoints/WIN-BOOTSTRAP/deployment.json`。

旧性能助手曾设置64灯与8个GI工作步，覆盖固定布局预算；调度队列在编译阻塞后积压，导致无帧样本百分位异常。现已保留构建预设、限制一个待执行调度任务、等待实际采样时间并拒绝助手失败。`windows-rtx-first` 的旧计时无效，不用于上表。

## 待办

继续检查正确尺寸下的逐光源遮挡、自阴影和太阳阴影，采集必要阶段成本并定位实现性重复工作；之后回到动态精确面、HiZ、反射状态、透明层、历史过滤和单包四档。系统性能优化仍在全部效果补齐后，目标约60FPS。当前检查点不关闭P04.2、P05.3或P11全链路。尚未发布release。
