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
from .shader_source import inline_shader, modernize, mark_native_stage

ROOT = Path(__file__).resolve().parents[2]

# OptiFine composite quads use [0,1] coordinates. Native GLSL avoids the
# legacy fixed-function ftransform() and needs no compatibility rewrite.
FULLSCREEN = '''in vec3 vaPosition;
void main() {
    gl_Position = vec4(vaPosition.xy * 2.0 - 1.0, 0.0, 1.0);
}
'''


def reserve_voxel_buffer(target):
    """Move the front-end C5 payload to C9 before adding the voxel backend."""
    backend = {
        target / "lib/conventional_lpv.glsl",
        target / "lib/conventional_voxel.glsl",
    }
    for path in target.rglob("*"):
        if path.suffix not in {".glsl", ".properties", ".vsh", ".fsh", ".gsh"}:
            continue
        if path in backend:
            continue
        source = path.read_text(encoding="utf-8")
        relocated = re.sub(r"\bcolortex5", "colortex9", source)
        relocated = re.sub(
            r"(\bRENDERTARGETS\s*:\s*)([0-9,\s]+)",
            lambda match: match[1] + re.sub(r"\b5\b", "9", match[2]),
            relocated,
        )
        relocated = re.sub(
            r"(\bDRAWBUFFERS\s*:\s*)([0-9N]+)",
            lambda match: match[1] + match[2].replace("5", "9"),
            relocated,
        )
        if relocated != source:
            path.write_text(relocated, encoding="utf-8")


def build(target, preset="LOW", colored=False):
    """Preserve the native four-profile UI while applying one initial profile."""
    target = Path(target)
    if target.exists():
        raise ValueError("Use a new baseline directory")
    shutil.copytree(ROOT / "shaders", target)
    reserve_voxel_buffer(target)
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
    quality = {"LOW": 1, "MID": 1, "HIGH": 2, "ULTRA": 3}[preset]
    settings = re.sub(r"(^#define GI_QUALITY )\d+", r"\g<1>" + str(quality), settings, flags=re.M)
    extra = (f"\n#define COLOURED_VOLUME_SIZE {volume} // [32 48 64 96]\n"
        f"#define COLOURED_LIGHT_STEPS {iterations} // [1 2 3 4]\n"
        "#define COLOURED_LIGHT_INTENSITY 1.0 // [0.0 0.5 0.75 1.0]\n"
        "#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0\n"
        "/*\nconst int colortex8Format = RGBA16F;\n"
        "const int colortex5Format = R32UI;\nconst int colortex10Format = RGBA32F;\n"
        "const int colortex11Format = RGBA8;\n*/\n"
        "const bool colortex8Clear = false;\nconst bool colortex5Clear = false;\n"
        "const bool colortex10Clear = false;\nconst bool colortex11Clear = false;\n#endif\n"
        "#if GI_QUALITY > 0\n/*\nconst int colortex12Format = RGBA16F;\n*/\n"
        "const bool colortex12Clear = false;\n#endif\n")
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
    properties = re.sub(r"^screen\.GI\s*=.*$",
        "screen.GI = GI_QUALITY GI_MULTIBOUNCE GI_STRENGTH GI_REFLECTANCE COLOURED_VOLUME_SIZE",
        properties, flags=re.M)
    for name, budget in {"LOW": (32, 1), "MID": (48, 2), "HIGH": (64, 3), "ULTRA": (96, 4)}.items():
        properties = re.sub(r"(^profile\." + name + r"\s*=.*)$",
            lambda found: found[1] + f" COLOURED_VOLUME_SIZE={budget[0]} COLOURED_LIGHT_STEPS={budget[1]}"
                + f" GI_QUALITY={dict(LOW=1, MID=1, HIGH=2, ULTRA=3)[name]}",
            properties, flags=re.M)
    properties = re.sub(r"^program\.world[\-\d]+/shadow\.enabled=.*$", "", properties, flags=re.M)
    properties += "\n#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0\nshadow.culling=false\n#endif\n"
    for dimension in ("world-1", "world1"):
        properties += ("#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0\n"
            f"program.{dimension}/shadow.enabled=true\n#else\n"
            f"program.{dimension}/shadow.enabled=false\n#endif\n")
    properties += "#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0\n"
    # J9 detaches fixed-size buffers from the scene FBO, including slots below
    # eight. C5 remains bound as an image while default draw-buffer restoration
    # and screen passes cannot overwrite its atomic material words.
    for number, size in enumerate((32, 48, 64, 96)):
        properties += ("#if" if number == 0 else "#elif") + f" COLOURED_VOLUME_SIZE == {size}\n"
        properties += f"size.buffer.colortex5={size * 8} {size * size // 8}\n"
        for buffer in (8, 10):
            properties += f"size.buffer.colortex{buffer}={size * 8} {size * size // 16 + 1}\n"
        properties += f"size.buffer.colortex11={size * 8} {(size * size // 16 + 1) * 3}\n"
    properties += "#endif\n#else\n"
    for buffer in (5, 8, 10, 11):
        properties += f"size.buffer.colortex{buffer}=1 1\n"
    properties += "#endif\n"
    properties += "#if GI_QUALITY > 0\n"
    for number, size in enumerate((32, 48, 64, 96)):
        properties += ("#if" if number == 0 else "#elif") + f" COLOURED_VOLUME_SIZE == {size}\n"
        properties += f"size.buffer.colortex12={size * 8} {(size * size // 16 + 1) * 6}\n"
    properties += "#endif\n#else\nsize.buffer.colortex12=1 1\n#endif\n"
    for dimension in ("", "world-1/", "world1/"):
        for step in range(6):
            program = "prepare" + (str(step) if step else "")
            condition = "ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0"
            if 1 <= step <= 3:
                condition = f"({condition}) && COLOURED_LIGHT_STEPS >= {step + 1}"
            properties += (f"#if {condition}\nprogram.{dimension}{program}.enabled=true\n"
                f"#else\nprogram.{dimension}{program}.enabled=false\n#endif\n")
        for step in range(6, 9):
            minimum = step - 5
            properties += (f"#if GI_QUALITY >= {minimum}\n"
                f"program.{dimension}prepare{step}.enabled=true\n#else\n"
                f"program.{dimension}prepare{step}.enabled=false\n#endif\n")
        # J9 resets flip indices at frame start. An odd number of transport
        # steps needs a copy into the other bank to preserve the latest field.
        properties += ("#if GI_QUALITY == 1 || GI_QUALITY == 3\n"
            f"program.{dimension}prepare9.enabled=true\n#else\n"
            f"program.{dimension}prepare9.enabled=false\n#endif\n")
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
        text += ("\noption.COLOURED_VOLUME_SIZE=" + ("光照体积范围" if chinese else "Light Volume Range")
            + "\noption.COLOURED_LIGHT_STEPS=" + ("彩色光照更新" if chinese else "Colored Light Updates")
            + "\noption.COLOURED_LIGHT_INTENSITY=" + ("彩色光照强度" if chinese else "Colored Light Intensity") + "\n")
        text += ("option.GI_QUALITY.comment=" + ("0关闭；1、2、3每帧分别更新1、2、3次。提高后收敛更快，开销增加。" if chinese else
                "0 disables GI; 1, 2 and 3 perform that many transport steps per frame. More work converges faster.") + "\n"
            + "option.GI_MULTIBOUNCE.comment=" + ("允许间接光在表面继续反射；关闭后仅保留一次表面反射。" if chinese else
                "Reflect indirect light again at surfaces. Disable for a single surface bounce.") + "\n"
            + "option.GI_STRENGTH.comment=" + ("只调整间接光亮度；0隐藏GI，但不停止体素更新。" if chinese else
                "Scales indirect light only. Zero hides GI while keeping transport active.") + "\n"
            + "option.GI_REFLECTANCE.comment=" + ("后续反弹的能量保留比例，与材质颜色共同限制能量。" if chinese else
                "Energy retained by later surface reflections, multiplied by material albedo.") + "\n")
        if chinese:
            text += ("option.ENABLE_COLOURED_LIGHTING.comment=启用附近光源的彩色直射；关闭后保留普通方块照明。GI开启时仍运行共享体素计算。\n"
                "option.COLOURED_VOLUME_SIZE.comment=GI和彩光共享的水平边长，竖直范围为一半；范围外保留原有环境光和方块照明。\n"
                "option.COLOURED_LIGHT_STEPS.comment=每帧传播次数；增加后光照随移动和编辑收敛更快。\n")
        else:
            text += ("option.ENABLE_COLOURED_LIGHTING.comment=Enable direct light colors. Ordinary block lighting remains when disabled; GI retains shared voxel work.\n"
                "option.COLOURED_VOLUME_SIZE.comment=Shared GI and colored-light horizontal extent; vertical extent is half. Existing lighting remains outside.\n"
                "option.COLOURED_LIGHT_STEPS.comment=Updates per frame. More updates converge faster after movement and block edits.\n")
        path.write_text(text, encoding="utf-8")
    palette = """
# Separate emission colors while the native front end retains aliases 101/102.
block.6000=minecraft:glowstone minecraft:lava minecraft:magma_block minecraft:shroomlight minecraft:jack_o_lantern
block.6001=minecraft:soul_torch minecraft:soul_wall_torch minecraft:soul_lantern minecraft:soul_campfire:lit=true
block.6002=minecraft:redstone_torch:lit=true minecraft:redstone_wall_torch:lit=true
block.6003=minecraft:sea_lantern
block.6004=minecraft:end_rod minecraft:beacon
block.6005=minecraft:verdant_froglight
block.6006=minecraft:pearlescent_froglight minecraft:ochre_froglight
block.6007=minecraft:crying_obsidian
block.6008=minecraft:redstone_lamp:lit=true
block.6009=minecraft:amethyst_cluster
block.6010=minecraft:torch minecraft:wall_torch minecraft:lantern minecraft:campfire:lit=true
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
    source = source.replace('#include "/lib/conventional_lpv.glsl"',
        '#include "/lib/conventional_lpv.glsl"\n#include "/lib/conventional_gi.glsl"')
    signature = "vec3 companionIndirect(vec3 viewPosition, vec3 normalView) {"
    source = source.replace(signature, signature + "\n#if GI_QUALITY > 0\n"
        "    return giSurfaceIrradiance(viewPosition, normalView);\n#endif")
    lighting.write_text(source, encoding="utf-8")
    # The conditional GPU backend include is inactive here. Include expanders
    # still resolve the path before conditional compilation.
    (target / "lib/world/layout.glsl").write_text(
        "// No world atlas in the conventional renderer baseline.\n", encoding="utf-8")
    clear = '''#version 450 core
#include "/lib/conventional_lpv.glsl"
layout(local_size_x=256) in;
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
#if COLOURED_VOLUME_SIZE == 32
const ivec3 workGroups = ivec3(64, 1, 1);
#elif COLOURED_VOLUME_SIZE == 48
const ivec3 workGroups = ivec3(216, 1, 1);
#elif COLOURED_VOLUME_SIZE == 64
const ivec3 workGroups = ivec3(512, 1, 1);
#else
const ivec3 workGroups = ivec3(1728, 1, 1);
#endif
#else
const ivec3 workGroups = ivec3(0, 0, 0);
#endif
void main() {
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
    int index = int(gl_GlobalInvocationID.x);
    ivec2 size = imageSize(colorimg5);
    ivec2 pixel = ivec2(index % size.x, index / size.x);
    ivec3 shape = lpvShape();
    int cells = shape.x * shape.y * shape.z;
    if (all(lessThan(pixel, size)) && index < cells) {
        imageStore(colorimg5, pixel, uvec4(0u));
        imageStore(colorimg5, pixel + ivec2(0, cells / size.x), uvec4(0u));
    }
#endif
}
'''
    barrier = '''#version 450 core
#include "/settings.glsl"
// OptiFine J9 rejects a 1x1x1 local size while scanning the source.
layout(local_size_x=2) in;
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
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
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
    vec3 lpvCentre = (shadowModelViewInverse * modelViewMatrix
        * vec4(vaPosition + modelOffset, 1.0)).xyz + cameraPosition + at_midBlock / 64.0;
    lpvCaptureGeometry(lpvCentre, at_midBlock);
#if GI_QUALITY > 0
    vec3 lpvAlbedo = textureLod(gtexture, mc_midTexCoord, 2.0).rgb * vaColor.rgb;
    lpvAlbedo = pow(max(lpvAlbedo, vec3(0.0)), vec3(2.2));
    lpvCaptureSurface(lpvCentre, int(round(mc_Entity.x)), lpvAlbedo,
        clamp(float(vaUV2.y) / 240.0, 0.0, 1.0));
#else
    lpvCaptureVertex(lpvCentre, int(round(mc_Entity.x)));
#endif
#endif
'''
                source = source.replace("void main() {", "void main() {" + capture)
                source = ('#include "/lib/conventional_voxel.glsl"\n'
                    'uniform sampler2D gtexture;\nin vec2 mc_midTexCoord;\n' + source)
            # Water vertex stages also include the shared image declarations.
            # Keep every native stage on the same image-capable GLSL version.
            path.write_text("#version 450 core\n" + source, encoding="utf-8")
        (folder / "shadow.csh").write_text(clear, encoding="utf-8")
        (folder / "prepare.csh").write_text(barrier, encoding="utf-8")
        for step in range(10):
            name = "prepare" + (str(step) if step else "")
            (folder / (name + ".vsh")).write_text("#version 450 core\n" + FULLSCREEN, encoding="utf-8")
            if step < 4:
                source = (ROOT / "shaders/program/conventional_lpv.fsh.glsl").read_text(encoding="utf-8")
            elif step == 4:
                source = (ROOT / "shaders/program/conventional_visibility.fsh.glsl").read_text(encoding="utf-8")
            elif step == 5:
                source = '''/* RENDERTARGETS: 8,10 */
uniform sampler2D colortex8;
uniform sampler2D colortex10;
layout(location=0) out vec4 result;
layout(location=1) out vec4 candidates;
void main() {
    result = texelFetch(colortex8, ivec2(gl_FragCoord.xy), 0);
    candidates = texelFetch(colortex10, ivec2(gl_FragCoord.xy), 0);
}
'''
            elif step < 9:
                source = (ROOT / "shaders/program/conventional_gi.fsh.glsl").read_text(encoding="utf-8")
            else:
                source = '''/* RENDERTARGETS: 12 */
uniform sampler2D colortex12;
layout(location=0) out vec4 result;
void main() {
    result = texelFetch(colortex12, ivec2(gl_FragCoord.xy), 0);
}
'''
            (folder / (name + ".fsh")).write_text("#version 450 core\n" + source, encoding="utf-8")
        for path in folder.glob("*.?sh"):
            if path.suffix == ".csh":
                continue
            source = inline_shader(path, target)
            if path.stem.startswith("prepare"):
                source = source.replace("texture2D(", "texture(")
            source = re.sub(r"^#define SIMPLE_DIMENSION[^\n]*\n", "", source, flags=re.M)
            first = source.index("\n") + 1
            world = -1 if dimension == "world-1" else 1 if dimension == "world1" else 0
            source = source[:first] + f"#define SIMPLE_DIMENSION ({world})\n" + source[first:]
            path.write_text(mark_native_stage(source), encoding="utf-8")
    manifest = {"architecture": "conventional-2d", "preset": preset,
                "colored_lighting": colored,
                "volume_size": volume, "iterations": iterations,
                "companion": False, "geometry_shader": False,
                "local_lighting": "atomic-voxels-source-candidates-rgb-transmission",
                "voxel_storage": "detached-colortex5-image",
                "voxel_shape": [volume, volume // 2, volume],
                "voxel_format": "R32UI",
                "reflection_geometry": "native-vertex-corner-votes",
                "global_illumination": "six-lobe-voxel-diffuse-transport",
                "gi_quality": quality,
                "scope": "standalone renderer with finite local-light and screen-space reflection approximations"}
    (target / "conventional-build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--preset", choices=("LOW", "MID", "HIGH", "ULTRA"), default="LOW")
    parser.add_argument("--colored", action="store_true")
    args = parser.parse_args()
    print(json.dumps(build(args.target, args.preset, args.colored), indent=2))
