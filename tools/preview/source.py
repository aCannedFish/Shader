"""Expand shader includes and reuse the installed OptiFine compatibility pass.

Captured macro headers fix the platform configuration. The converter runs only
text transforms, and generated code is checked against the game's own exports
before the snapshot is accepted for replay.
"""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

from .minecraft import classpath, load_version

INCLUDE = re.compile(r'^\s*#include\s+"([^"]+)"')
COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.DOTALL)
MACROS = re.compile(r"^#define MC_[^\n]*", re.MULTILINE)
TOKEN = re.compile(
    r"[A-Za-z_]\w*|0[xX][0-9A-Fa-f]+[uU]?|"
    r"(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?[uUfF]?|"
    r"<<=|>>=|\+\+|--|&&|\|\||\^\^|==|!=|<=|>=|<<|>>|"
    r"\+=|-=|\*=|/=|%=|&=|\|=|\^=|[^\s]"
)
HOST_CONSTANT = re.compile(
    r"\bconst\s+\w+\s+(shadow\w*|sunPathRotation|noiseTextureResolution|ambientOcclusionLevel|"
    r"colortex\d+(?:Format|Clear|ClearColor|MipmapEnabled))\s*=\s*([^;]+);"
)


def digest(path):
    """Hash a file to detect source or capture changes independently of mtimes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalized(text):
    """Compare shader tokens while ignoring comments, whitespace and line maps."""
    text = COMMENT.sub(lambda match: "\n" * match.group(0).count("\n") or " ", text)
    text = re.sub(r"^\s*#line[^\n]*", "", text, flags=re.MULTILINE)
    tokens = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            # Preprocessor directives end at a logical line, unlike normal code.
            tokens.extend(("<directive>", *TOKEN.findall(line), "</directive>"))
        else:
            tokens.extend(TOKEN.findall(line))
    return " ".join(tokens)


def expand(path, shader_root, files=None, stack=()):
    """Expand each include occurrence, preserving GLSL include guards and maps."""
    path = path.resolve()
    if path in stack:
        raise RuntimeError(f"Cyclic shader include: {path}")
    if not path.is_relative_to(shader_root.resolve()):
        raise RuntimeError(f"Include escapes shader directory: {path}")
    if files is None:
        files = {path: 0}
    index = files.setdefault(path, len(files))
    result = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = INCLUDE.match(line)
        if match:
            name = match.group(1)
            target = shader_root / name.lstrip("/") if name.startswith("/") else path.parent / name
            target = target.resolve()
            child_index = files.setdefault(target, len(files))
            result.append(f"#line 1 {child_index}")
            result.append(expand(target, shader_root, files, (*stack, path)))
            result.append(f"#line {number + 1} {index}")
        else:
            result.append(line)
    return "\n".join(result) + "\n"


def build_converter(root, instance, java_home):
    """Extract the installed loader's classes locally and compile host bridges."""
    game_root = instance.parent.parent
    version = load_version(instance)
    library = next(item for item in version["libraries"] if item["name"].startswith("optifine:OptiFine:"))
    artifact = library.get("downloads", {}).get("artifact", {}).get("path")
    if artifact:
        loader = game_root / "libraries" / artifact
    else:
        _, name, release = library["name"].split(":")[:3]
        loader = game_root / "libraries" / "optifine" / name / release / f"{name}-{release}-installer.jar"
    jar = root / ".preview" / "optifine-api.jar"
    with zipfile.ZipFile(loader) as installed, zipfile.ZipFile(jar, "w", zipfile.ZIP_DEFLATED) as extracted:
        for name in installed.namelist():
            if name.startswith("srg/") and name.endswith(".class"):
                extracted.writestr(name.removeprefix("srg/"), installed.read(name))
    cp = str(jar) + ":" + classpath(game_root, version)
    classes = root / ".preview" / "converter-classes"
    classes.mkdir(parents=True, exist_ok=True)
    java_sources = sorted((root / "tools" / "preview" / "java").rglob("*.java"))
    subprocess.run([
        str(java_home / "bin" / "javac"), "--release", "21", "-proc:none",
        "-cp", cp, "-d", str(classes), *map(str, java_sources),
    ], check=True)
    converter = {
        "java": str(java_home / "bin" / "java"),
        "classpath": str(classes) + ":" + cp,
        "loader_sha256": digest(loader),
    }
    (root / ".preview" / "converter.json").write_text(json.dumps(converter, indent=2))
    return converter


def generate(root, converter, snapshot, output, verify=False, shader_root=None):
    """Generate all entry points using captured macros and the real remapper."""
    original = root / ".preview" / "game" / "shaderpacks" / "debug" / "shaders"
    inputs = output / "expanded"
    inputs.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    shader_root = shader_root or root / "shaders"
    arguments = []
    for name in snapshot:
        source = expand(shader_root / name, shader_root)
        # Minecraft 1.21.11 moves lightmap coordinates to texture unit 2.
        source = source.replace("gl_MultiTexCoord1", "gl_MultiTexCoord2")
        source = re.sub(r"gl_TextureMatrix\s*\[\s*1\s*\]", "gl_TextureMatrix[2]", source)
        header = "\n".join(snapshot[name]["macros"])
        source = re.sub(r"(#version[^\n]*\n)", r"\1" + header + "\n#line 2 0\n", source, count=1)
        input_file = inputs / name
        output_file = output / name
        input_file.parent.mkdir(parents=True, exist_ok=True)
        output_file.parent.mkdir(parents=True, exist_ok=True)
        input_file.write_text(source)
        arguments.extend((str(input_file), str(output_file)))
    subprocess.run([
        converter["java"], "-cp", converter["classpath"], "ConvertShader", *arguments,
    ], check=True, capture_output=True, text=True)
    if verify:
        mismatches = [name for name in snapshot
                      if normalized((output / name).read_text()) != normalized((original / name).read_text())]
        if mismatches:
            raise RuntimeError("Offline loader conversion differs from capture: " + ", ".join(mismatches))
    return {name: (output / name).read_text() for name in snapshot}


def loader_properties_digest(path):
    """Track rendering directives while allowing labels and option pages to change."""
    directives = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('#') and not re.match(
            r'^#\s*(?:if|ifdef|ifndef|elif|else|endif|define|undef|include)\b', line
        ):
            continue
        key = line.split('=', 1)[0].strip()
        if key == 'sliders' or key == 'screen' or key.startswith(
            ('screen.', 'option.', 'slider.', 'value.')
        ):
            continue
        directives.append(line)
    return hashlib.sha256('\n'.join(directives).encode()).hexdigest()


def host_configuration(shader_root):
    """Record loader-owned settings that cannot change in a fixed GPU recording."""
    constants = []
    outputs = []
    for file in sorted(shader_root.rglob("*")):
        if file.suffix not in (".glsl", ".vsh", ".gsh", ".fsh"):
            continue
        text = file.read_text()
        constants.extend((name, re.sub(r"\s+", "", value)) for name, value in HOST_CONSTANT.findall(text))
        outputs.extend(re.findall(r"(?:DRAWBUFFERS|RENDERTARGETS)\s*:\s*([^*\n]+)", text))
    return {
        # A new companion recording is required for the reserved-row terrain field.
        "terrain_atmosphere_layout": int((shader_root / "lib/ground_fog.glsl").exists()),
        "ore_glow_layout": int((shader_root / "lib/ore_emission.glsl").exists()),
        "properties": loader_properties_digest(shader_root / "shaders.properties"),
        "blocks": digest(shader_root / "block.properties") if (shader_root / "block.properties").exists() else None,
        "constants": [[name, value] for name, value in sorted(constants)],
        "outputs": sorted(outputs),
        # Effect resolutions also change the loader's viewports. A fixed recording
        # cannot apply a different viewport merely by replacing its shader source.
        "viewport_options": [list(row) for row in sorted(re.findall(
            r"^#define (BLOOM_RESOLUTION|VOLUMETRIC_RESOLUTION) ([^\s]+)",
            (shader_root / "settings.glsl").read_text(), re.MULTILINE))],
        "companion_options": [list(row) for row in sorted(re.findall(
            r"^#define (LOCAL_LIGHT_COUNT|LOCAL_LIGHT_RADIUS|LOCAL_SHADOW_RESOLUTION|LOCAL_SHADOW_UPDATES|GI_VOLUME_SIZE|GI_BOUNCES|GI_PROPAGATION_STEPS|GI_WORK_PER_FRAME|GI_REFLECTANCE|LIGHTING_UPDATE_INTERVAL|BLOCK_LIGHT_STRENGTH|SUNLIGHT_STRENGTH|MOONLIGHT_STRENGTH) ([^\s]+)",
            (shader_root / "settings.glsl").read_text(), re.MULTILINE))],
        "textures": [[str(file.relative_to(shader_root)), digest(file)]
                     for file in sorted((shader_root / "textures").rglob("*"))
                     if file.is_file() and file.suffix != ".md"],
    }


def shader_snapshot(root):
    """Store each exported shader's platform header for later offline conversion."""
    exported = root / ".preview" / "game" / "shaderpacks" / "debug" / "shaders"
    result = {}
    for file in sorted(exported.rglob("*")):
        if file.suffix in (".vsh", ".gsh", ".fsh") and (root / "shaders" / file.relative_to(exported)).exists():
            result[file.relative_to(exported).as_posix()] = {
                "macros": list(dict.fromkeys(MACROS.findall(file.read_text())))
            }
    if not result:
        raise RuntimeError("No OptiFine shader exports found in capture directory")
    return result
