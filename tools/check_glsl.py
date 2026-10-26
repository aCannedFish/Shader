#!/usr/bin/env python3
"""
check_glsl.py —— 不启动游戏就能做光影编译检查

原理：
  1. OptiFine 的 #include 不是 GLSL 标准语法，所以先把它们递归展开成
     单个文件（按"包含一次"处理，和 #ifndef 头文件保护的行为一致）。
     路径规则与 OptiFine 相同：以 / 开头表示相对 shaders/ 根目录，
     否则表示相对当前文件所在目录。
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
    阴影、颜色和光学逻辑需要固定场景 GPU 重放或实际游戏验证
    （见 docs/development.md）。
"""

import os
import argparse
from pathlib import Path
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


def resolve_include(current, name):
    """按 OptiFine 的规则求被包含文件：以 / 开头相对 shaders/ 根目录，否则相对当前文件目录。

    调用方的工作目录是 shaders/，因此返回值也相对 shaders/。
    """
    if name.startswith("/"):
        return os.path.normpath(name[1:])
    return os.path.normpath(os.path.join(os.path.dirname(current), name))


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
                name = match.group(1)
                target = resolve_include(path, name)
                if not os.path.isfile(target):
                    raise FileNotFoundError(f"Missing shader include: {path}: {name}")
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

    stage = {".vsh": "vert", ".gsh": "geom", ".fsh": "frag", ".csh": "comp"}[Path(path).suffix]
    out_path = os.path.join(out_dir, Path(path).as_posix().replace("/", "-")
                            .replace(".vsh", ".vert").replace(".gsh", ".geom")
                            .replace(".fsh", ".frag").replace(".csh", ".comp"))

    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))

    result = subprocess.run(
        [validator, "-S", stage, out_path],
        capture_output=True, text=True,
    )
    output = result.stdout + result.stderr

    errors = [line for line in output.splitlines() if "ERROR:" in line]
    if result.returncode and not errors:
        errors = [output.strip() or f"Compiler exited with status {result.returncode}"]
    warnings = [line for line in output.splitlines() if "WARNING:" in line]

    if verbose and warnings:
        print("    警告:")
        for warning in warnings[:10]:
            print("      " + warning)

    return errors


def discover_programs(shader_dir):
    """Only executable root and dimension entry points belong to the stage set."""
    result = []
    for directory in [Path(shader_dir), *sorted(Path(shader_dir).glob("world*"))]:
        if directory.is_dir():
            for suffix in ("*.vsh", "*.gsh", "*.fsh", "*.csh"):
                result.extend(str(file.relative_to(shader_dir)) for file in directory.glob(suffix))
    return sorted(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--shader-dir", type=Path, default=Path(__file__).resolve().parents[1] / "shaders")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / ".check")
    args = parser.parse_args()
    shader_dir = args.shader_dir.resolve()
    out_dir = args.output.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    validator = find_validator()
    programs = discover_programs(shader_dir)
    if not programs:
        parser.error("No shader stages found")
    os.chdir(shader_dir)
    failed = []
    groups = {}
    computes = {}
    suffixes = {".vsh": ".vert", ".gsh": ".geom", ".fsh": ".frag", ".csh": ".comp"}
    for program in programs:
        errors = check_program(validator, program, str(out_dir), args.verbose)
        if errors:
            failed.append((program, errors))
            print("FAIL " + program)
        else:
            print("OK   " + program)
        path = Path(program)
        if path.suffix == ".csh":
            computes[program] = out_dir / (path.as_posix().replace("/", "-")[:-4] + ".comp")
            continue
        groups.setdefault(str(path.with_suffix("")), {})[path.suffix] = out_dir / (
            path.as_posix().replace("/", "-")[:-4] + suffixes[path.suffix])
    linked = 0
    for name, stages in groups.items():
        if ".vsh" not in stages or ".fsh" not in stages:
            failed.append((name, ["Incomplete graphics program: vertex and fragment stages are required"]))
            continue
        command = [validator, "-l", *[str(stages[key]) for key in (".vsh", ".gsh", ".fsh") if key in stages]]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            failed.append((name + " link", (result.stdout + result.stderr).splitlines()))
        else:
            linked += 1
    print(f"\nChecked {len(programs)} stages and linked {linked}/{len(groups)} programs")
    compute_linked = 0
    for name, source in computes.items():
        result = subprocess.run([validator, "-l", str(source)], capture_output=True, text=True)
        if result.returncode:
            failed.append((name + " compute link", (result.stdout + result.stderr).splitlines()))
        else:
            compute_linked += 1
    if computes:
        print(f"Linked {compute_linked}/{len(computes)} compute programs separately")
    for name, errors in failed:
        print(name)
        for error in errors[:20]:
            print("  " + error)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
