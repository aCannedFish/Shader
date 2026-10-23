#!/usr/bin/env bash
#
# deploy.sh —— 把光影同步到 Minecraft 的 shaderpacks 目录
#
# 背景：这台机器的游戏目录是【版本隔离】的，也就是
#     ~/minecraft/versions/1.21.11-Forge-OptiFine/
# 本机游戏资源统一放在 ~/minecraft/。
# 放错地方的话，游戏的光影列表里根本看不到这个光影包。
# 这个脚本会同时同步到所有可能的位置，避免再踩这个坑。
#
# 用法：
#     bash tools/deploy.sh          # 同步
#
# 改完代码后跑一次，然后在游戏里按 F3 + R 重载光影即可。
# 也可以直接把这个脚本绑到编辑器的一键运行上。

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/shaders"
NAME="SimpleShader"

if [ ! -d "$SRC" ]; then
    echo "找不到光影目录：$SRC" >&2
    exit 1
fi

TARGETS=(
    "$HOME/minecraft/versions/1.21.11-Forge-OptiFine"
    "$HOME/minecraft"
)

if [ "$#" -gt 0 ]; then
    TARGETS=("$@")
fi

for game_dir in "${TARGETS[@]}"; do
    # 只同步到已经存在的游戏目录，不无中生有
    if [ ! -d "$game_dir" ]; then
        echo "跳过（目录不存在）：$game_dir"
        continue
    fi

    dest="$game_dir/shaderpacks/$NAME"
    mkdir -p "$dest"
    # --delete 保证删掉的文件在游戏里也消失（否则改错删的文件会留着）
    rsync -a --delete "$SRC/" "$dest/shaders/"
    echo "已同步 -> $dest/shaders"
done

echo
echo "完成。进游戏后按 F3 + R 重载光影。"
