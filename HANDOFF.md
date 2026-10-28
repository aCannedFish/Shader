# 开发交接

2026-10-28 WATER-02-TRIAL：修正关闭风浪时落雨涟漪也消失的开关联动，水下读取同一雨波法线。四档及四组开关共八组完整编译通过，422文件已备份同步实际实例并保留用户设置；本次增量原生开关对照与性能仍待验证。

2026-10-28 WATER-01-TRIAL：按用户要求将可加载的v4试用检查点备份同步到实际Windows实例，422文件哈希一致，用户选项保留。后续每个可加载检查点先同步供用户测试，完整视觉与性能验收继续推进；本次不代表水体目标完成。

2026-10-28 GI-01：已实现六方向局部体素多弹 GI，接入日月、天光和局部灯的表面反射；新增独立质量、多弹、强度和反射率选项。RTX4060 原生单弹/多弹/封闭室、High 连续 WASD 与三维度通过；Low 彩光+GI 在1080p/视距12下静止81.777FPS、移动68.508FPS。已备份同步真实实例，原有选项逐字节保留。详见 docs/global-illumination.md。

2026-10-28 RGB-MOVE2：将体素从shadowcolor1迁到固定C5 image，前端C5迁C9，避免J9阴影光栅覆盖整数体素；覆盖权重按连续相机计算。已用正常W/D/S/A输入连续移动80秒验证，详见docs/rgb-movement.md。

2026-10-27 RGB-STABLE：用户村庄 (-458,89,713) 定位地形阶段 8..16 误含实体/手部；采集改为明确接受 8、9、16。旧传播保留，全光源重构未部署。同步当前光照和后处理六项默认值；验证与边界见 docs/rgb-stability.md。

2026-10-27 更新：当前生产工作区为 F:/Shader 的 main，入口为 tools.preview.conventional。VIS-02 修正水下天空、彩光并发采集与逐灯遮挡、显示色调、雨天反射雾色和云层远距堆积；使用说明及验证边界见 docs/visual-repairs.md。当前变更包含接手时已有的未提交实现，原始工作区和最终源码均在检查点归档，不能仅用 HEAD 标识完整源码。以下迁移分支和旧全世界图集记录供历史对照。

交接日期：2026-10-25。用户要求停止当前机器上的实施，将现有进度同步到GitHub，后续转到Windows继续调试开发。

当前版本是未完成的无配套Mod迁移开发版。用户在原Mac上观察到接近0/0 FPS；在第一代Intel Core Ultra 7、32GB DDR5、RTX 4060 Laptop的Windows设备上约5 FPS，出现阴影异常、一次进入游戏时崩溃，另一次加载卡顿数分钟后才进入。当前没有该Windows设备的崩溃日志、堆栈或GPU记录，根因尚未确认。不要把本次交接理解成性能或迁移验收通过。

## 快速接手

1. 获取 `https://github.com/aCannedFish/Shader.git` 的 `ygt/no-mod-reflections` 分支。不要直接从默认main或旧release继续，也不要把迁移分支强行覆盖到main。
2. 阅读本文件、根目录PLAN.md和docs/migration/state.json。PLAN.md与docs/migration/plan.md是同步的当前执行计划，保留12阶段、49工作包。
3. 确认当前游戏加载的是交接包中的完整迁移Shader，且配套 `SimpleShaderLighting` Mod未加载。直接安装仓库根目录shaders会得到旧前端路径。
4. 在Windows记录实际Minecraft、OptiFine、Java、显卡渲染器、分辨率、视距与驱动。先复现崩溃、长时间加载和阴影问题；没有证据前不归因为显存不足、核显或某个具体算法。
5. 按后文命令建立构建环境。修改实际源码后重新生成完整包，再同步到用户真实的Windows实例目录。

可直接给新窗口的首条指令：

> 请读取HANDOFF.md、PLAN.md和docs/migration/state.json，在ygt/no-mod-reflections分支接手。主平台是Windows、第一代Ultra 7、32GB DDR5、RTX 4060 Laptop，不再适配Mac。当前迁移版约5 FPS且发生过崩溃、长时间加载和阴影异常，先取得本机实际证据并定位稳定性/实现错误，再继续完成无Mod迁移和反射重构。保持全部效果类别，系统优化在效果补齐后进行，允许随实现消除保持结果的重复计算；最终提供约30 FPS的低档。每个通过检查的检查点备份并同步到实际游戏实例。不要把旧的Mac编译或截图当作Windows验收，也不要重做无关数据探针。

## 版本来源

| 项目 | 值 |
| --- | --- |
| GitHub | https://github.com/aCannedFish/Shader |
| 开发分支 | ygt/no-mod-reflections |
| 当前渲染实现 | 2f6052e，修复喷涌核心身份与光源发现 |
| 上一进度提交 | dc709e0，记录检查点及每检查点部署要求 |
| 房间反射修复 | b1172fa，基础辐射/直接高光分离及环境缓存 |
| 水面历史检查点 | 0f4704d |
| 迁移冻结基线 | f02cbb22666bd67e8a6c96119c41b0e931546e9c |
| 原工作区提交 | b0e651c0b422af84d1a0ea5d2a610f6677c652da |
| 交接源码版本 | 以包内MANIFEST.json的source_commit及Git日志为准 |

迁移是在隔离工作树实施的。原Mac工作区有25项已修改或未跟踪文件，经逐项比较，内容均已包含在f02cbb2冻结基线中，没有遗漏的基线后用户修改；原工作区没有被重置或覆盖。

本轮停止实施后没有新增动态精确表面算法，也没有提交性能优化。交接仅补齐了静态构建数据和Minecraft JAR路径入口，已从不含local-docs和既有.preview的干净源码导出重建，817个产物与当前部署包逐文件完全一致。

## 用户要求

- 最终只依赖Minecraft 1.21.11、OptiFine J9和光影ZIP，不再依赖配套光照Mod。开发测试助手只能建场景、固定镜头、计时和读回，不能给目标Shader上传几何、光源、地表、水深或矿石数据。
- 保留已有全部效果类别；迁移不要求逐像素复刻错误的旧实现。允许系统重构反射、高光和管线，优先解决岸线白边、叶隙错误天空、遮挡遗漏和无色黑轮廓。
- 水体保持深蓝、适度透明、水色与场景倒影兼顾，只看清浅处；水下保持可玩能见度，不恢复影响视野的全反射锥限制。
- 光照要柔和自然，减少过亮的火把光圈、方块形边界和自阴影；参考Sildur、BSL、Complementary的算法和优化思路，禁止照抄风格和实现。
- 完成效果后再系统优化。可以使用保持观感的近似、缓存和调度手段，不能靠关闭GI、点光阴影、反射或alpha规则获得帧率。Windows低档目标约30 FPS，必须报告实际测试条件。
- 后续以Windows设备为主，不再承担旧Mac或OpenGL4.1兼容门槛。可评估目标平台上OptiFine允许的compute/其他GPU路径，选用前验证接口、资源和同步；不擅自换Minecraft版本或加载器。
- 每个通过检查的检查点立即备份并同步完整生成包到用户实际游戏实例，记录deployment.json并告知重载。保持原用户修改；不自动发布release或替换最新正式release。
- 工作以Shader实现为主，避免大量无直接渲染作用的验证。编译通过、某张截图或“存在倒影”均不足以证明全部正确。

## 当前进度

当前工作包是P04.2。状态记录中19项已完成、27项进行中、3项待开始；“已完成”主要来自原Mac的历史证据，不能据此宣布Windows验收通过。

| 范围 | 已有实现 | 尚缺内容 |
| --- | --- | --- |
| P00—P03 | 冻结基线、隔离测试、平台/布局验证、世界坐标与近远场采集、部分方块形状和失效调试 | 受Windows驱动/接口变化影响的链路需复验 |
| P04 | 原版状态、静态模型面/UV、随机模型选择、偏移、染色、alpha与玻璃路径；喷涌核心本体识别 | 动态方块实体精确表面、风环/眼部、状态歧义、复杂alpha和玻璃完整验收 |
| P05 | GPU发现光源、稳定槽位、彩色传播、逐光源六面阴影和玻璃滤色 | 全部发光状态、满额选择、编辑延迟与自阴影完整验收 |
| P06 | 球谐工作场、默认四次反弹、完整周期发布及变化失效 | 能量、穿墙、收敛、交互与跨原点完整验收 |
| P07 | P07.1基础辐射源拆分已验收；SSR/世界查询、隐藏面着色和共同材质后端已接入 | 真正层级SSR、完整状态/天空分类、复杂遮挡与动态精确面 |
| P08 | 水/玻璃/雨层缓冲分离、光学合成、岸线/轮廓对应、高光修正 | 剩余白边黑边、复杂半透明叠层和所有参考场景验收 |
| P09 | 水面半分辨率重建和历史；高档多方向代码已接入 | 全材质过滤/历史、高档原生质量、单ZIP运行时四档切换 |
| P10 | 原生地面/顶棚/树冠/水面采集和缓存；P10.3矿石GPU遮罩与16→64→16重载已验收 | 跨原点/连续编辑、天气和三维度完整回归 |
| P11 | 交接补齐可移植静态输入和JAR环境变量入口 | 全链路、实际性能、清理旧构建依赖及纯OptiFine干净实例 |

已保留的效果类别包括：日月天空与天气、体积云和云影、地面/森林/山坡雾、维度氛围、植被风摆与透射、材质和水面反射、水体折射/吸收、水下雾和光柱/可选焦散、雨丝/水花/积水、彩色局部光、点光阴影、多次漫反射GI、矿物自发光、HDR/泛光/色调映射。列表表示迁移目标与已接入类别，不表示各项已完成验收。

## 已知故障

| 优先级 | 问题 | 当前证据与处理边界 |
| --- | --- | --- |
| 最高 | Windows约5 FPS；Mac接近0/0 FPS | 用户实际反馈；没有可靠的目标机整帧/阶段耗时。当前LOW不可称为可玩档 |
| 最高 | 一次崩溃；另一次加载卡顿数分钟 | Windows日志、堆栈、驱动信息尚未取得，未确认OOM、驱动编译或其他根因 |
| 最高 | Windows阴影明显异常 | 尚无该机的细节截图或GPU数据；Mac房间局部修复不能证明此问题已解决 |
| 高 | 动态表面不完整 | 世界模型查询遇到动画模型仍返回WORLD_UNCERTAIN；保守占用不能当真实反射面 |
| 高 | 反射分类与遮挡 | HiZ未完成，未知/域外/耗尽尚未在所有消费者正确处理；不能自动变成天空或黑色 |
| 高 | 岸线/叶片/轮廓伪影 | 部分简化场景有改善，复杂场景及所有档位仍未充分验收，不能宣称全面消除 |
| 中 | 粗糙材质与时域 | 水面有历史；普通材质尚无完整统一历史，高档质量及动态拒绝不足，LOW仍可见重建/摩尔纹 |
| 中 | 半透明粒子 | 雨层/水花已有专用处理，普通有色粒子与多层玻璃/水的组合未完整验收 |
| 中 | 原点/帧计数 | frameCounter按720720循环，但light_selection及point_shadow仍有直接frame-1比较；环境部分周期与1000格相机重置的关系未完整验证 |
| 中 | 单包档位 | 构建器目前生成四个不同布局包；尚未实现单ZIP切档。不能只改LOCAL_LIGHT_COUNT或GI尺寸而不重建布局 |
| 中 | 构建/预览遗留 | 预览启动器和若干导出工具仍写死macOS ARM64库规则或/usr/libexec/java_home；Windows暂用启动器手动运行 |

下一机器至少保留失败当次的latest.log、crash-reports、hs_err_pid文件和启动器日志，记录Java及实际OpenGL renderer/driver。不要把所有OpenGL错误沿用旧结论归为OptiFine噪音，也不要仅凭笔记本配置认定游戏已经使用RTX独显。

## 关键修复

石英房间中，三支真实火把可以各自在不同反射面形成柔和光斑；额外的锐利副本、漂移亮线是实现问题。b1172fa通过同场景消融定位：关闭场景反射会移除副本，关闭点光GGX只移除合法软光斑，关闭泛光并不能修复。随后严格验证反射射线与接收平面，拆开漫反射/自发光的基础源和已计算的直接GGX，并在小型发光几何与解析高光之间分配权重。静止序列中地面主要光斑质心漂移低于0.01像素；这不是所有材质或Windows阴影的验收。

喷涌核心的原生几何为6/16格壳体或8/16格激活框架，但J9实际提供了前一个末影箱的blockEntityId=9376、mc_Entity.x=0，spriteBounds也为旧值。2f6052e通过真实三角形尺寸、实际UV及当前资源图像的双哈希匹配本体；透明像素隐藏RGB归零，避免图集填色误判。两种状态均发现独立15级光源，末影箱保留7级光源，均生成了阴影图。此路径只覆盖本体，不是完整动态表面迁移；现有正确喷涌核心状态编号会保留，残留编号下的干湿状态歧义仍待处理。

## 源码入口

| 位置 | 用途 |
| --- | --- |
| tools/preview/migration_full.py | 完整迁移包组装入口；注入GPU后端、现代化顶点属性、重排程序、展开include |
| tools/preview/migration_world.py | 世界生产阶段、prepare列表、静态资源与布局生成 |
| tools/migration_layout.py | 唯一资源账本，当前schema 17；C6区域、精度和分配 |
| tools/world_catalog.py、world_assets.py、world_surfaces.py | 原版状态/模型/材质的不可变表构建 |
| tools/migration_inputs.py、tools/data/minecraft-1.21.11/ | 已纳入Git的原版注册表和偏移数据，gzip解压后读取 |
| shaders/program/world_capture.*.glsl | 原生阴影阶段GS采集、太阳与点光深度、世界/环境观察 |
| shaders/program/world_resolve.fsh.glsl | 原始观察解析、历史/覆盖、UV、状态与原点发布 |
| shaders/lib/world/model_query.glsl、reflection_query.glsl | 静态模型求交、世界反射与隐藏面辐射 |
| shaders/lib/world/reflection_material.glsl、reflection_hybrid.glsl | 材质反射及SSR/世界候选结合；以实际文件为准 |
| shaders/lib/world/lighting_backend.glsl | 旧companion API名字到纯GPU数据的适配；名字保留不代表运行时需要Mod |
| shaders/lib/world/light_selection.glsl、point_shadow.glsl | GPU光源、槽位、调度和逐光源可见度 |
| shaders/lib/world/gi*.glsl、program/world_gi*.glsl | 球谐GI、工作场与发布 |
| shaders/lib/world/environment.glsl、ore_*.glsl | 地形/水柱字段及矿石遮罩 |
| shaders/lib/world/dynamic_identity.glsl、program/world_dynamic_sprites.fsh.glsl | 喷涌核心本体身份缓存 |
| shaders/lib/water*.glsl、material*.glsl、program/gbuffers_*.glsl | 既有视觉前端；由组装器接入新后端 |
| tools/preview/CaptureScenes.java | 原生固定镜头、测试场景、读回和性能记录助手 |

不要直接编辑生成包中的展开着色器后以为源码已保存。完整构建会把公共函数展开进各入口；修改仓库lib后必须重建，否则游戏可能仍在执行旧副本。根目录shaders独立打包及tools/build_release.py仍面向旧路径，不是当前无Mod候选的生产命令。

## 渲染管线

当前总体顺序：原生shadow GS采集 → prepare更新世界、光源、点光阴影、玻璃滤色、GI及环境 → 不透明gbuffers → deferred基础辐射/背景发布 → 原生水、玻璃、天气和粒子 → 水面反射历史 → 水体/水下光学 → 云/空气/光柱合成 → 泛光和最终显示。

当前完整LOW共有73个prepare入口；三维度共609个着色器阶段、303个链接程序。这是编译/链接统计，不能用来证明性能或驱动运行正确。已检查的LOW逻辑分配账本约621.7 MiB，不含所有驱动开销；实际格式和峰值显存尚待Windows校准。C6为5888×2304，阴影采集附件为2688×2688。

| 缓冲 | 当前语义 |
| --- | --- |
| C0 | 最终合成前的完整显示辐射 |
| C1 | 几何/水覆盖及加法雨层统计，随阶段复用 |
| C2 | 光照/材质与有色玻璃等分层数据 |
| C3 | 已合成的不透明显示背景，供水/玻璃透射；后期复用 |
| C4 | 未加相机雾、无本帧反射反馈及直接点光GGX的反射辐射源；水光学之后复用 |
| C5 | 不透明期为反射基础源；deferred发布后清空，转为打包水面法线/深度/散射 |
| C6 | 固定尺寸持久世界图集，含世界/材质/光源/点光图/GI/环境/天空缓存 |
| C7 | 场景相对尺寸的水反射缓存/历史 |

历史文档中“C3为反射源、C4为透射背景”已过时。当前语义见docs/migration/resources.md最后的管线说明。固定尺寸C6和场景尺寸附件分开绘制，保持成对写入和副本一致性，不允许读写同一实际纹理。

LOW阴影GS为5次调用，每调用声明91顶点、约1001输出分量，接近旧平台1024限制；其他档预算不同。原生输入使用vaPosition/vaUV0/vaUV2、modelViewMatrix和projectionMatrix。J9在存在自定义gbuffers纹理数组时才设置部分C4—C7采样器，普通diffuse图集配置承担触发作用，不要随意删掉。worldTextureAtlas绑定到纹理单元12，noisetex承载静态表而不是噪声；天空噪声另走shadowcolor0。

## 性能线索

以下是代码审视得到的测量候选，没有做过目标机阶段计时，不能称为已确认瓶颈：

- shadow GS对原生三角形进行多次调用，除日月深度外还写世界记录、模型选择/UV、点光六面和环境；应测驱动GS吞吐及编译代价。
- world_resolve每帧绘制完整持久图集，含大量读取、字段判断和静态状态复制；多个局部阶段随后再成对更新。
- LOW远场为128×96×128格，光源归约需要多层全域处理；HiZ尚未真正接入，反射也有世界DDA成本。
- 玻璃滤色在多个接收体素与活动灯之间做射线查询；GI在多个字段和RGB球谐通道中可能重复求相同步进。当前生成8个GI子步程序，即使GI_WORK_PER_FRAME较小，部分程序仍会执行复制。
- 整个包入口多且公共代码展开，加载卡顿可能与驱动编译有关，也可能来自其他原因；必须结合实际日志/调用耗时区分。

目标机上先用相同小场景区分启动/编译时间、CPU提交、GPU阶段和后台限帧；在完整效果落地后再统一进行缓存、批处理、分层更新及可选compute路径重构。没有完成任何“已达30 FPS”或“性能提升若干倍”的测量。现有LOW只是较小资源预算，不能沿用旧release关于“低档可玩”的表述。

本地J9二进制存在compute程序加载与调度代码，但本分支尚未实现compute Shader，其资源绑定、barrier和其他接口在Windows未验证。用户取消Mac兼容前提后可评估这条路线，不能把它当作现成已经修复性能的实现。

## 构建

先安装Git、64位Python和启动器所需的Java，Minecraft固定1.21.11与OptiFine J9。历史Mac构建使用Python 3.13.1、NumPy 2.5.1，原生游戏检查使用JDK 25；Windows实际Java由目标实例决定并记录。glslangValidator.exe用于离线语法/链接检查，应加入PATH；它不能验证运行时FBO、图像或性能。

在线获取源码，PowerShell：

```powershell
git clone --branch ygt/no-mod-reflections --single-branch https://github.com/aCannedFish/Shader.git Shader
Set-Location Shader
git status --short
git log -3 --oneline
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-migration.txt
$env:PYTHONUTF8 = "1"
$env:MINECRAFT_JAR = "D:\Minecraft\versions\1.21.11\1.21.11.jar"
```

最后一行必须换成目标机实际客户端JAR，里面应有assets/minecraft/blockstates；不要选择OptiFine安装器或仅含补丁的JAR。没有把Minecraft本体打进交接包。PYTHONUTF8用于避免Windows默认编码读取中文源码时出错。

交接包也包含离线Git历史，在解压目录可执行 `git clone --branch ygt/no-mod-reflections .\Shader-source.bundle Shader`，然后进入Shader继续上述环境和构建步骤。离线克隆后可用 `git remote set-url origin https://github.com/aCannedFish/Shader.git` 改回远端地址；先核对提交，再推送后续工作。

生成与检查完整迁移包：

```powershell
.\.venv\Scripts\python.exe -m tools.preview.migration_full --target .preview\windows-low\shaders --preset LOW --world-reflections
if ($LASTEXITCODE -ne 0) { throw "Shader build failed" }
.\.venv\Scripts\python.exe tools\check_glsl.py --shader-dir .preview\windows-low\shaders --output .check\windows-low
if ($LASTEXITCODE -ne 0) { throw "Shader check failed" }
```

构建器参数为LOW、MEDIUM、HIGH、ULTRA。当前只能分别生成，不要在游戏中修改布局尺寸来冒充单包切档。构建本身不需要Forge或配套Mod；要使用Java测试助手则另需适配其Windows启动流程。

两份过去藏在local-docs中的输入现在已经纳入Git：tools/data/minecraft-1.21.11/vanilla-blocks.json.gz与offsets.json.gz。它们只是静态方块注册表与离散偏移，没有世界或实时光源数据。manifest记录压缩前后哈希。使用这些输入和显式MINECRAFT_JAR重建后，输出与旧输入路径生成的当前完整包逐文件相同。

## 安装预览

交接包中的current-shader.zip是当前完整LOW包，可直接放入目标实例shaderpacks并选中；它是故障复现/开发候选，不是发布版。确认SimpleShaderLighting没有加载；若刚移除JAR，须完全重启客户端，F3+R无法卸载Java Mod。用户其他游戏Mod不要无差别删除。

后续源码构建完成后，先确认启动器显示的真实实例目录。下面PowerShell中的路径必须修改，旧文件移至实例外层备份目录，避免作为第二份光影被选择：

```powershell
$game = "D:\Minecraft\versions\1.21.11-OptiFine"
$pack = Join-Path $game "shaderpacks\SimpleShader"
$dest = Join-Path $pack "shaders"
$backup = Join-Path $game (".simpleshader-backups\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force $pack, $backup | Out-Null
if (Test-Path $dest) { Move-Item $dest (Join-Path $backup "shaders") }
Copy-Item -Recurse .preview\windows-low\shaders $dest
```

选中SimpleShader或按F3+R重载。记录源码提交、预设、构建目录、实际实例、旧包位置及当前包哈希到检查点deployment.json；不要把空构建或未通过检查的实验包同步过去。保留/检查原光影选项，避免旧DEBUG_VIEW或不匹配的布局选项影响判断。

tools/deploy.sh默认复制的是仓库根目录旧shaders，且目标是Mac路径，Windows不要直接运行。tools/build_release.py也尚未改成迁移版生产入口。

## 调试场景

先用Windows启动器手动运行。tools/preview/minecraft.py的library_allowed仍固定osx/ARM64，若干工具调用/usr/libexec/java_home或CGL/Objective-C原生探针，尚不能作为Windows自动测试已适配的证据。需要自动化时只移植相关启动/场景/计时部分，不先重做全部旧数据探针。任何目标实例仍须断言未加载配套光照Mod。

关键原生场景在CaptureScenes.java中：

| 场景 | 用途 |
| --- | --- |
| seam_room及scene_off/specular_off/bloom_off | 房间重复反射消融；三支火把各自合法高光与错误副本区分 |
| seam_room_sequence_0/1/2、seam_room_motion | 静止连续帧与第二固定角度；motion场景并非真正连续移动 |
| migration_dynamic_emitters、其_active变体 | 末影箱/喷涌核心身份、独立光源和激活状态 |
| water_leaf_wall、water_user_shore | 叶隙后有墙/山体、岸线白带、反射轮廓与天空混入 |
| reflect_wall_metal、玻璃/水体场景 | 彩色材质反射及不同透明层的观察关系 |
| underwater_deep、其_down、underwater_cave | 不同视角的水柱缓存和封闭水域 |
| ore_glow及resource64/resource_restore | 矿石宿主抑制和资源重载 |
| perf_static、perf_walk | 纯Shader有整帧记录入口；perf_edits的无Mod路径仍未实现 |

没有测试助手时，可在有作弊权限的创造模式测试副本中建小石英房间，固定午夜/晴天并摆三支火把，观察地面、墙角接缝及遮挡；再以桥底水池、树叶后方彩色墙和开阔水岸分别检查。不要在用户唯一存档上运行批量fill命令。

原对比截图对应存档“新的世界 (1)”，种子-4404489444783266461；用户水岸位置约4689、62、-1062。私有存档未纳入Git或交接包，新机器可用测试副本或重建场景。原参考包文件夹名为Sildur、BSL、Complementary，未将这些第三方包打入本交接包。

## 证据范围

交接包evidence保留房间反射、动态身份和水面历史的代表性说明/截图/读回，以及当前编译与部署清单。旧Mac的全部local-docs、游戏副本和预览运行目录没有搬运；state.json里的其他历史路径在新机器上可能不存在。这些缺失的历史文件不能当作新的通过证据；源码、静态输入和当前完整安装包已经提供，可继续独立构建。

代表性检查点：P10-room-reflections、P04-dynamic-identity、P09-water-history。P04-dynamic-identity最后的新增三角面严格性条件已用两组实际输入检查，未改变接受结果；最终完整包重新通过609/303离线检查，但并未完成Windows驱动与帧率验收。

Mac最近部署时间2026-10-25 21:13，包文件树SHA-256为180b9ebb16cb2075769796121e9f675c20e8fd317307823159e812d3ece018df。旧Shader与SimpleShaderLighting-0.2.4.jar保存在原实例.simpleshader-backups/20261025-211311中；这些Mac路径只供恢复历史，不是Windows默认配置。

## 下一步

下一窗口收到继续指令后，先核对分支与交接MANIFEST、实际加载的ZIP和Mod状态，保留Windows失败日志，复现崩溃/长加载/阴影并确定故障发生在哪一阶段。涉及OpenGL状态、数据布局和驱动行为的改动，需要该Windows设备原生检查；不得靠Mac重放或CPU模拟宣布解决。

随后回到P04.2，将真实动态面的位置、UV、alpha接入worldTraceReflection；当前只有保守占用和本体身份，不能继续把占用范围当真实命中。补齐P04—P10剩余模块、完整反射状态/HiZ、粗糙度过滤/历史和单包四档，再按P11进行整帧性能优化、约30 FPS低档和干净OptiFine实例验收。用户允许重构和保持观感的trick，Windows能力可以支持新的实现选择，但每次变更须保留明确的数据契约与回归范围。

完成标准仍是全部效果有无Mod实现、原反射缺陷及阴影延迟通过、四档/性能记录完整、干净实例只装OptiFine和ZIP可运行。不要把本文件列出的某个局部修复替代整体完成，也不要在用户未要求时发布新release。
