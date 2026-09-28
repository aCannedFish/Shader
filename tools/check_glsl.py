#!/usr/bin/env python3
"""
check_glsl.py —— 不启动游戏就能做光影编译检查

原理：
  1. OptiFine 的 #include 不是 GLSL 标准语法，所以先把它们递归展开成
     单个文件（按"包含一次"处理，和 #ifndef 头文件保护的行为一致）；
  2. settings.glsl 里的 `const int colortex0Format = RGBA16F;` 是 OptiFine
     专有语法，真正的 GLSL 编译器不认识 RGBA16F 这个标识符，
     所以这里补上一组 #define 把它们替换成 0；
  3. 把结果喂给 glslangValidator，逐程序检查语法与类型。

用法：
    python3 tools/check_glsl.py            # 检查 shaders/ 下所有程序
    python3 tools/check_glsl.py -v         # 同时打印警告

依赖：
    macOS:  brew install glslang
    Ubuntu: apt install glslang-tools

注意：
    这个脚本只能发现【语法/类型】错误。
    "阴影位置错了""颜色不对"这类逻辑问题，只能靠进游戏 + 调试视图排查
    （见 docs/07-调试排错与性能.md）。
"""

import os
import re
import sys
import glob
import shutil
import subprocess

# OptiFine 的颜色缓冲区格式常量，需要一个占位定义才能被 GLSL 编译器接受
FORMAT_TOKENS = [
    "R8", "R16", "R16F", "R32F",
    "RG8", "RG16", "RG16F", "RG32F",
    "RGB8", "RGB16", "RGB16F", "RGB32F",
    "RGBA8", "RGBA16", "RGBA16F", "RGBA32F",
    "R11F_G11F_B10F",
]

INCLUDE_RE = re.compile(r'\s*#include\s+"([^"]+)"')


def find_validator():
    for name in ("glslangValidator", "glslang"):
        path = shutil.which(name)
        if path:
            return path
    sys.exit("找不到 glslangValidator。macOS 请先运行：brew install glslang")


def inline_includes(path, seen):
    """递归展开 #include，seen 用来模拟头文件保护（同一个文件只展开一次）。"""
    if path in seen:
        return []
    seen.add(path)

    lines = []
    with open(path, encoding="utf-8") as handle:
        for line in handle.read().splitlines():
            match = INCLUDE_RE.match(line)
            if match:
                target = match.group(1).lstrip("/")
                if not os.path.exists(target):
                    lines.append("// !! 找不到被包含的文件: " + target)
                    continue
                lines.extend(inline_includes(target, seen))
            else:
                lines.append(line)
    return lines


def check_program(validator, path, out_dir, verbose):
    lines = [line for line in inline_includes(path, set()) if line.strip()]

    if not lines or not lines[0].startswith("#version"):
        lines.insert(0, "#version 120")

    # 插入格式常量的占位定义（必须在 #version 之后）
    lines.insert(1, "\n".join("#define %s 0" % token for token in FORMAT_TOKENS))

    is_vertex = path.endswith(".vsh")
    stage = "vert" if is_vertex else "frag"
    out_path = os.path.join(out_dir, os.path.basename(path)
                            .replace(".vsh", ".vert").replace(".fsh", ".frag"))

    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))

    result = subprocess.run(
        [validator, "-S", stage, out_path],
        capture_output=True, text=True,
    )
    output = result.stdout + result.stderr

    errors = [line for line in output.splitlines() if "ERROR:" in line]
    warnings = [line for line in output.splitlines() if "WARNING:" in line]

    if verbose and warnings:
        print("    警告:")
        for warning in warnings[:10]:
            print("      " + warning)

    return errors


def main():
    verbose = "-v" in sys.argv

    shader_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "shaders")
    shader_dir = os.path.normpath(shader_dir)
    os.chdir(shader_dir)

    validator = find_validator()
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".check")
    os.makedirs(out_dir, exist_ok=True)

    programs = sorted(glob.glob("*.vsh") + glob.glob("*.fsh"))
    failed = []

    for program in programs:
        errors = check_program(validator, program, out_dir, verbose)
        if errors:
            failed.append((program, errors))
            print("FAIL " + program)
        else:
            print("OK   " + program)

    print()
    print("通过 %d / %d" % (len(programs) - len(failed), len(programs)))

    for program, errors in failed:
        print("=" * 60)
        print(program)
        for error in errors[:20]:
            print("   " + error)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
