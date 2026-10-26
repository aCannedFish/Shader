"""Build an isolated conventional renderer with optional GPU colored lighting.

The artistic front end uses ordinary shadow maps and screen-space effects.
An optional compact RGB field replaces the companion's colored light. All
four profiles stay selectable in one pack and share an independent light toggle.
"""

import argparse
import json
from pathlib import Path
import re
import shutil
from .migration_full import inline_shader, modernize, mark_native_stage

ROOT = Path(__file__).resolve().parents[2]

# OptiFine composite quads use [0,1] coordinates. Native GLSL avoids the
# legacy fixed-function ftransform() and needs no compatibility rewrite.
FULLSCREEN = '''in vec3 vaPosition;
void main() {
    gl_Position = vec4(vaPosition.xy * 2.0 - 1.0, 0.0, 1.0);
}
'''


def build(target, preset="LOW", colored=False):
    """Preserve the native four-profile UI while applying one initial profile."""
    target = Path(target)
    if target.exists():
        raise ValueError("Use a new baseline directory")
    shutil.copytree(ROOT / "shaders", target)
    properties = (target / "shaders.properties").read_text(encoding="utf-8")
    profile = "MEDIUM" if preset == "MID" else preset
    match = re.search(r"^profile\." + profile + r"\s*=\s*(.+)$", properties, re.M)
    if match is None:
        raise ValueError("Unknown source profile: " + profile)
    settings = (target / "settings.glsl").read_text(encoding="utf-8")
    values = dict(token.split("=", 1) for token in match[1].split() if "=" in token)
    values.update(ENABLE_COMPANION_LIGHTING="0", ENABLE_COLOURED_LIGHTING=str(int(colored)))
    for name, value in values.items():
        settings, count = re.subn(r"(^#define\s+" + name + r"\s+)\S+",
            lambda found: found[1] + value, settings, flags=re.M)
        if not count:
            settings, count = re.subn(r"(const\s+\w+\s+" + name + r"\s*=\s*)[^;]+",
                lambda found: found[1] + value, settings)
        if not count:
            raise ValueError("Profile option is not declared: " + name)
    # The clear flag appears early in settings.glsl. Put its controlling
    # option before that flag so both GLSL and OptiFine parse the same branch.
    color_option = re.search(
        r"#ifndef ENABLE_COLOURED_LIGHTING\n"
        r"#define ENABLE_COLOURED_LIGHTING [^\n]+\n"
        r"#endif\n",
        settings,
    )
    if color_option is None:
        raise ValueError("Colored-light option declaration is missing")
    settings = settings.replace(color_option.group(0), "", 1)
    settings = settings.replace(
        "#define SETTINGS_GLSL\n",
        "#define SETTINGS_GLSL\n" + color_option.group(0),
        1,
    )
    volume, iterations = {"LOW": (32, 1), "MID": (48, 2), "HIGH": (64, 3), "ULTRA": (96, 4)}[preset]
    extra = (f"\n#define COLOURED_VOLUME_SIZE {volume} // [32 48 64 96]\n"
        f"#define COLOURED_LIGHT_STEPS {iterations} // [1 2 3 4]\n"
        "#define COLOURED_LIGHT_INTENSITY 1.0 // [0.0 0.5 0.75 1.0]\n"
        "#if ENABLE_COLOURED_LIGHTING == 1\n"
        "/*\nconst int colortex8Format = RGBA16F;\n*/\nconst bool colortex8Clear = false;\n#endif\n")
    settings = settings.replace("const bool colortex1Clear = true;",
        "#if ENABLE_COLOURED_LIGHTING == 1\nconst bool colortex1Clear = false;\n"
        "#else\nconst bool colortex1Clear = true;\n#endif")
    end = settings.rfind("#endif")
    settings = settings[:end] + extra + settings[end:]
    (target / "settings.glsl").write_text(settings, encoding="utf-8")
    properties = properties.replace("profile.MEDIUM", "profile.MID")
    # Remove the former companion's inert budgets from the profile contract.
    # The new volume budgets below are the only colored-light quality controls.
    properties = re.sub(
        r"\s+(?:LOCAL_LIGHT_\w+|LOCAL_SHADOW_\w+|GI_\w+)=\S+",
        "",
        properties,
    )
    properties = properties.replace("ENABLE_COMPANION_LIGHTING ", "")
    properties = properties.replace("screen = <profile>", "screen = <profile> ENABLE_COLOURED_LIGHTING")
    properties = re.sub(r"^screen\.LOCAL_LIGHTS\s*=.*$",
        "screen.LOCAL_LIGHTS = ENABLE_COLOURED_LIGHTING COLOURED_VOLUME_SIZE COLOURED_LIGHT_STEPS COLOURED_LIGHT_INTENSITY",
        properties, flags=re.M)
    properties = properties.replace("[LOCAL_LIGHTS] [GI]", "[LOCAL_LIGHTS]")
    for name, budget in {"LOW": (32, 1), "MID": (48, 2), "HIGH": (64, 3), "ULTRA": (96, 4)}.items():
        properties = re.sub(r"(^profile\." + name + r"\s*=.*)$",
            lambda found: found[1] + f" COLOURED_VOLUME_SIZE={budget[0]} COLOURED_LIGHT_STEPS={budget[1]}",
            properties, flags=re.M)
    properties = re.sub(r"^program\.world[\-\d]+/shadow\.enabled=.*$", "", properties, flags=re.M)
    properties += "\n#if ENABLE_COLOURED_LIGHTING == 1\nshadow.culling=false\n#endif\n"
    for dimension in ("world-1", "world1"):
        properties += ("#if ENABLE_COLOURED_LIGHTING == 1\n"
            f"program.{dimension}/shadow.enabled=true\n#else\n"
            f"program.{dimension}/shadow.enabled=false\n#endif\n")
    properties += "#if ENABLE_COLOURED_LIGHTING == 1\n"
    for number, size in enumerate((32, 48, 64, 96)):
        properties += ("#if" if number == 0 else "#elif") + f" COLOURED_VOLUME_SIZE == {size}\n"
        properties += f"size.buffer.colortex8={size * 8} {size * size // 16 + 1}\n"
    properties += "#endif\n#else\nsize.buffer.colortex8=1 1\n#endif\n"
    for dimension in ("", "world-1/", "world1/"):
        for step in range(8):
            program = "prepare" + (str(step) if step else "")
            condition = "ENABLE_COLOURED_LIGHTING == 1"
            if 1 <= step <= 3:
                condition += f" && COLOURED_LIGHT_STEPS >= {step + 1}"
            properties += (f"#if {condition}\nprogram.{dimension}{program}.enabled=true\n"
                f"#else\nprogram.{dimension}{program}.enabled=false\n#endif\n")
    (target / "shaders.properties").write_text(properties, encoding="utf-8")
    for path in (target / "lang").glob("*.lang"):
        text = path.read_text(encoding="utf-8").replace("profile.MEDIUM", "profile.MID")
        chinese = path.stem.lower() == "zh_cn"
        labels = {"LOW": "Low（低）", "MID": "Mid（中）", "HIGH": "High（高）", "ULTRA": "Ultra（极高）"}
        for name in labels:
            label = labels[name] if chinese else name.title()
            text = re.sub(r"^profile\." + name + r"\s*=.*$",
                "profile." + name + "=" + label, text, flags=re.M)
            comment = ("调整阴影、云、反射和体积采样预算；彩色光照独立开关。" if chinese else
                       "Adjusts shadows, clouds, reflections and volumes; colored lighting is independent.")
            text = re.sub(r"^profile\." + name + r"\.comment\s*=.*$",
                "profile." + name + ".comment=" + comment, text, flags=re.M)
        text = re.sub(
            r"^screen\.LOCAL_LIGHTS\s*=.*$",
            "screen.LOCAL_LIGHTS=" + ("彩色光照" if chinese else "Colored Lighting"),
            text,
            flags=re.M,
        )
        text += ("\noption.COLOURED_VOLUME_SIZE=" + ("彩色光照范围" if chinese else "Colored Light Range")
            + "\noption.COLOURED_LIGHT_STEPS=" + ("彩色光照更新" if chinese else "Colored Light Updates")
            + "\noption.COLOURED_LIGHT_INTENSITY=" + ("彩色光照强度" if chinese else "Colored Light Intensity") + "\n")
        if chinese:
            text += ("option.ENABLE_COLOURED_LIGHTING.comment=启用附近光源的彩色传播；关闭可节省计算，保留普通方块照明。\n"
                "option.COLOURED_VOLUME_SIZE.comment=相机周围的水平边长，竖直范围为一半；范围外使用普通方块照明。\n"
                "option.COLOURED_LIGHT_STEPS.comment=每帧传播次数；增加后光照随移动和编辑收敛更快。\n")
        else:
            text += ("option.ENABLE_COLOURED_LIGHTING.comment=Propagate nearby light colors. Disable to save work while retaining ordinary block lighting.\n"
                "option.COLOURED_VOLUME_SIZE.comment=Horizontal side length around the camera; vertical extent is half. Ordinary block lighting covers the outside.\n"
                "option.COLOURED_LIGHT_STEPS.comment=Updates per frame. More updates converge faster after movement and block edits.\n")
        path.write_text(text, encoding="utf-8")
    palette = """
# Separate emission colors while the native front end retains aliases 101/102.
block.6000=minecraft:torch minecraft:wall_torch minecraft:lantern minecraft:glowstone minecraft:lava minecraft:magma_block minecraft:shroomlight minecraft:jack_o_lantern minecraft:campfire:lit=true
block.6001=minecraft:soul_torch minecraft:soul_wall_torch minecraft:soul_lantern minecraft:soul_campfire:lit=true
block.6002=minecraft:redstone_torch:lit=true minecraft:redstone_wall_torch:lit=true minecraft:redstone_lamp:lit=true
block.6003=minecraft:sea_lantern
block.6004=minecraft:end_rod minecraft:beacon
block.6005=minecraft:verdant_froglight
block.6006=minecraft:pearlescent_froglight minecraft:ochre_froglight
block.6007=minecraft:crying_obsidian minecraft:amethyst_cluster
"""
    block_file = target / "block.properties"
    assigned = {block for line in palette.splitlines() if line.startswith("block.")
                for block in line.split("=", 1)[1].split()}
    lines = []
    for line in block_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("block.") and "=" in line:
            key, blocks = line.split("=", 1)
            kept = [block for block in blocks.split() if block not in assigned]
            if not kept:
                continue
            line = key + "= " + " ".join(kept)
        lines.append(line)
    block_file.write_text("\n".join(lines) + "\n" + palette, encoding="utf-8")
    lighting = target / "lib/companion_lighting.glsl"
    source = lighting.read_text(encoding="utf-8")
    source = source.replace("#define LIB_COMPANION_LIGHTING_GLSL",
        '#define LIB_COMPANION_LIGHTING_GLSL\n#include "/lib/conventional_lpv.glsl"')
    signature = "vec3 companionBlockLight(vec3 viewPosition, vec3 normalView, vec2 lmCoord, vec3 nativeRadiance) {"
    source = source.replace(signature, signature + "\n#if ENABLE_COLOURED_LIGHTING == 1\n"
        "    return lpvBlockLight(viewPosition, normalView, nativeRadiance);\n#endif")
    lighting.write_text(source, encoding="utf-8")
    # The conditional GPU backend include is inactive here. Include expanders
    # still resolve the path before conditional compilation.
    (target / "lib/world/layout.glsl").write_text(
        "// No world atlas in the conventional renderer baseline.\n", encoding="utf-8")
    clear = '''#version 450 core
#include "/lib/conventional_lpv.glsl"
layout(local_size_x=256) in;
#if ENABLE_COLOURED_LIGHTING == 1
#if COLOURED_VOLUME_SIZE == 32
const ivec3 workGroups = ivec3(64, 1, 1);
#elif COLOURED_VOLUME_SIZE == 48
const ivec3 workGroups = ivec3(216, 1, 1);
#elif COLOURED_VOLUME_SIZE == 64
const ivec3 workGroups = ivec3(512, 1, 1);
#else
const ivec3 workGroups = ivec3(1728, 1, 1);
#endif
layout(rgba16f) uniform image2D colorimg1;
#else
const ivec3 workGroups = ivec3(0, 0, 0);
#endif
void main() {
#if ENABLE_COLOURED_LIGHTING == 1
    int index = int(gl_GlobalInvocationID.x);
    ivec2 size = imageSize(colorimg1);
    ivec2 pixel = ivec2(index % size.x, index / size.x);
    ivec3 shape = lpvShape();
    if (all(lessThan(pixel, size)) && index < shape.x * shape.y * shape.z)
        imageStore(colorimg1, pixel, vec4(0.0));
#endif
}
'''
    barrier = '''#version 450 core
#include "/settings.glsl"
// OptiFine J9 rejects a 1x1x1 local size while scanning the source.
layout(local_size_x=2) in;
#if ENABLE_COLOURED_LIGHTING == 1
const ivec3 workGroups = ivec3(1, 1, 1);
#else
const ivec3 workGroups = ivec3(0, 0, 0);
#endif
void main() {}
'''
    for dimension in ("", "world-1", "world1"):
        folder = target / dimension
        for path in folder.glob("*.?sh"):
            stage = path.suffix[1:]
            source = inline_shader(path, target)
            source = modernize(source, stage, world_entity=False)
            if path.stem == "shadow" and stage == "vsh":
                capture = '''
#if ENABLE_COLOURED_LIGHTING == 1
    vec3 lpvCentre = (shadowModelViewInverse * modelViewMatrix
        * vec4(vaPosition + modelOffset, 1.0)).xyz + cameraPosition + at_midBlock / 64.0;
    lpvCaptureVertex(lpvCentre, int(round(mc_Entity.x)));
#endif
'''
                source = source.replace("void main() {", "void main() {" + capture)
                source = '#include "/lib/conventional_voxel.glsl"\n' + source
            version = "450" if path.stem == "shadow" and stage == "vsh" else "330"
            path.write_text(f"#version {version} core\n" + source, encoding="utf-8")
        (folder / "shadow.csh").write_text(clear, encoding="utf-8")
        (folder / "prepare.csh").write_text(barrier, encoding="utf-8")
        for step in range(8):
            name = "prepare" + (str(step) if step else "")
            (folder / (name + ".vsh")).write_text("#version 330 core\n" + FULLSCREEN, encoding="utf-8")
            if step < 4:
                source = (ROOT / "shaders/program/conventional_lpv.fsh.glsl").read_text(encoding="utf-8")
            elif step < 6:
                source = '''/* RENDERTARGETS: 8 */
uniform sampler2D colortex8;
layout(location=0) out vec4 result;
void main() {
    result = texelFetch(colortex8, ivec2(gl_FragCoord.xy), 0);
}
'''
            else:
                source = '''/* RENDERTARGETS: 1 */
layout(location=0) out vec4 result;
void main() {
    result = vec4(1.0);
}
'''
            (folder / (name + ".fsh")).write_text("#version 450 core\n" + source, encoding="utf-8")
        for path in folder.glob("*.?sh"):
            if path.suffix == ".csh":
                continue
            source = inline_shader(path, target)
            source = re.sub(r"^#define SIMPLE_DIMENSION[^\n]*\n", "", source, flags=re.M)
            first = source.index("\n") + 1
            world = -1 if dimension == "world-1" else 1 if dimension == "world1" else 0
            source = source[:first] + f"#define SIMPLE_DIMENSION ({world})\n" + source[first:]
            path.write_text(mark_native_stage(source), encoding="utf-8")
    manifest = {"architecture": "conventional-2d", "preset": preset,
                "colored_lighting": colored,
                "volume_size": volume, "iterations": iterations,
                "companion": False, "geometry_shader": False,
                "scope": "isolated performance baseline, not a completed migration"}
    (target / "conventional-build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--preset", choices=("LOW", "MID", "HIGH", "ULTRA"), default="LOW")
    parser.add_argument("--colored", action="store_true")
    args = parser.parse_args()
    print(json.dumps(build(args.target, args.preset, args.colored), indent=2))
