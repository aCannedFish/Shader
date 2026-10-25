# 构建输入

这两份gzip文件来自迁移基线保存的Minecraft 1.21.11静态导出：方块注册表、状态属性、渲染/发光元数据，以及离散模型偏移值。原路径分别为local-docs/migration/registry/runtime-v2/vanilla-blocks.json和offset-profiles-v2/offsets.json。

它们不包含存档、玩家、区块、实时几何、活动光源或光照缓存。生成光影时，实际模型资源仍从用户设置的MINECRAFT_JAR读取；运行时世界数据仍由Shader采集。

manifest.json记录原始内容与gzip的SHA-256。交接时已核对哈希，并以这些文件重建完整LOW包，产物与原本机数据路径构建的包逐文件一致。修改Minecraft版本或重新导出时，应更新文件、清单和相关验收，不能静默混用不同注册表。
