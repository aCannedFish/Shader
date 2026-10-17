"""Launch the installed Forge/OptiFine client in an isolated capture directory.

The original world is copied before any test commands run. Existing local
libraries and assets are reused; launcher credentials are neither read nor sent.
"""

import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import zipfile


def library_allowed(library):
    """Apply the installed version's platform rules to a library entry."""
    rules = library.get("rules")
    if not rules:
        return True
    allowed = False
    for rule in rules:
        specification = rule.get("os", {})
        if specification.get("name", "osx") not in ("osx", "universal"):
            continue
        architecture = specification.get("arch")
        if architecture and architecture not in ("aarch64", "arm64"):
            continue
        if rule.get("features"):
            continue
        allowed = rule.get("action") == "allow"
    return allowed


def load_version(instance, visited=()):
    """Resolve installed launcher inheritance while preserving child library overrides."""
    instance = Path(instance).resolve()
    metadata = instance / (instance.name + '.json')
    if metadata in visited:
        raise RuntimeError('Cyclic installed version inheritance')
    child = json.loads(metadata.read_text())
    parent_name = child.get('inheritsFrom')
    if not parent_name:
        return child
    parent = load_version(instance.parent / parent_name, (*visited, metadata))
    merged = {**parent, **child}
    merged['jar'] = child.get('jar', parent.get('jar', parent['id']))
    libraries = {}
    for library in [*parent.get('libraries', []), *child.get('libraries', [])]:
        parts = library['name'].split(':')
        key = tuple(parts[:2] + parts[3:])
        libraries[key] = library
    merged['libraries'] = list(libraries.values())
    merged['arguments'] = {
        kind: [*parent.get('arguments', {}).get(kind, []),
               *child.get('arguments', {}).get(kind, [])]
        for kind in ('game', 'jvm')
    }
    return merged


def classpath(game_root, version):
    """Resolve artifacts from local metadata and refuse missing dependencies."""
    files = []
    for library in version["libraries"]:
        if not library_allowed(library):
            continue
        relative = library.get("downloads", {}).get("artifact", {}).get("path")
        if relative is None:
            parts = library["name"].split(":")
            group, artifact, release = parts[:3]
            suffix = "-" + parts[3] if len(parts) == 4 else ""
            relative = (
                f"{group.replace('.', '/')}/{artifact}/{release}/"
                f"{artifact}-{release}{suffix}.jar"
            )
        path = game_root / "libraries" / relative
        if not path.exists():
            raise RuntimeError(f"Missing installed library: {path}")
        files.append(str(path))
    jar_name = version.get("jar", version["id"])
    jar = game_root / "versions" / jar_name / f"{jar_name}.jar"
    if jar.exists():
        files.append(str(jar))
    return os.pathsep.join(files)


def update_options(path, values):
    """Update only the isolated instance's options, preserving other entries."""
    lines = path.read_text().splitlines() if path.exists() else []
    current = dict(line.split(":", 1) for line in lines if ":" in line)
    current.update(values)
    path.write_text("\n".join(f"{key}:{value}" for key, value in current.items()) + "\n")


def build_mod(root, java_home, cp, game_directory):
    """Compile a small Forge capture helper against the installed libraries."""
    classes = root / ".preview" / "helper-classes"
    classes.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        str(java_home / "bin" / "javac"), "--release", "21", "-proc:none",
        "-classpath", cp, "-d", str(classes),
        str(root / "tools" / "preview" / "CaptureScenes.java"),
    ], check=True)
    metadata = '''modLoader="javafml"
loaderVersion="[61,)"
license="MIT"
[[mods]]
modId="simpleshader_preview"
version="0.1.0"
displayName="SimpleShader Capture"
description="Local fixed-scene capture helper."
'''
    jar = game_directory / "mods" / "simpleshader-preview.jar"
    jar.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(jar, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("META-INF/mods.toml", metadata)
        archive.writestr("pack.mcmeta", json.dumps({
            "pack": {
                "description": "SimpleShader isolated capture helper",
                "min_format": [94, 1],
                "max_format": 94,
            },
        }))
        for file in classes.rglob("*.class"):
            archive.write(file, file.relative_to(classes).as_posix())


def capture(root, runtime, source_instance, source_world, java_home, scenes=None,
            width=960, height=540, render_distance=6, shader_root=None):
    """Capture the fixed real client scenes, leaving the source instance untouched."""
    if platform.system() != "Darwin":
        raise RuntimeError("This capture launcher currently targets macOS.")
    source_instance = Path(source_instance).expanduser().resolve()
    java_home = Path(java_home).expanduser().resolve()
    game_root = source_instance.parent.parent
    version = load_version(source_instance)
    cp = classpath(game_root, version)
    captures = root / ".preview" / "captures"
    trace = captures / "minecraft.trace"
    if trace.exists():
        raise RuntimeError(f"Capture already exists; use capture --refresh to preserve and replace it: {trace}")
    game_directory = root / ".preview" / "game"
    game_directory.mkdir(parents=True, exist_ok=True)
    # Interposed CGL calls can race Forge's early-window hand-off on macOS.
    # Only the isolated preview config is changed; Minecraft creates its normal
    # game window and the source instance keeps its existing Forge settings.
    forge_config = game_directory / "config" / "fml.toml"
    forge_config.parent.mkdir(parents=True, exist_ok=True)
    lines = forge_config.read_text().splitlines() if forge_config.exists() else []
    lines = [line for line in lines if not line.strip().startswith("earlyWindowControl")]
    forge_config.write_text("\n".join([*lines, "earlyWindowControl = false"]) + "\n")
    world = game_directory / "saves" / "ShaderPreview"
    if not world.exists():
        shutil.copytree(source_instance / "saves" / source_world, world)
    for name in ("options.txt", "optionsof.txt", "optionsshaders.txt"):
        source = source_instance / name
        if source.exists():
            shutil.copy2(source, game_directory / name)
    update_options(game_directory / "options.txt", {
        "enableVsync": "false", "maxFps": "10", "fullscreen": "false",
        "pauseOnLostFocus": "false", "renderDistance": str(render_distance),
        "simulationDistance": "5", "resourcePacks": "[]",
    })
    # The isolated capture must finish rebuilding distant edited sections.
    update_options(game_directory / "optionsof.txt", {
        "ofChunkUpdates": "5", "ofChunkUpdatesDynamic": "true",
        "ofLazyChunkLoading": "false",
    })
    shaderpack = game_directory / "shaderpacks" / "SimpleShader" / "shaders"
    shutil.copytree(shader_root or root / "shaders", shaderpack, dirs_exist_ok=True)
    properties = game_directory / "optionsshaders.txt"
    lines = properties.read_text().splitlines() if properties.exists() else []
    lines = [line for line in lines if not line.startswith("shaderPack=")]
    properties.write_text("\n".join(lines + ["shaderPack=SimpleShader"]) + "\n")
    build_mod(root, java_home, cp, game_directory)
    release = (root / 'VERSION').read_text().strip()
    companion = root / 'dist' / f'SimpleShaderLighting-{release}.jar'
    if companion.exists():
        shutil.copy2(companion, game_directory / "mods" / companion.name)

    natives = source_instance / "natives-macos-arm64"
    captures.mkdir(parents=True, exist_ok=True)
    arguments = [
        str(java_home / "bin" / "java"), "-XstartOnFirstThread", "-Xmx3G",
        "-Dshaders.debug.save=true", f"-Djava.library.path={natives}",
        f"-Dsimpleshader.preview.width={width}", f"-Dsimpleshader.preview.height={height}",
        f"-Dorg.lwjgl.system.SharedLibraryExtractPath={natives}",
        f"-Djna.tmpdir={natives}", f"-Dio.netty.native.workdir={natives}",
        "-Dminecraft.launcher.brand=SimpleShaderPreview",
        "-Dminecraft.launcher.version=0.1", "-cp", cp, version["mainClass"],
        "--username", "ShaderPreview", "--version", version["id"],
        "--gameDir", str(game_directory), "--assetsDir", str(game_root / "assets"),
        "--assetIndex", version["assetIndex"]["id"],
        "--uuid", "27e06ad8c89132e6a78982bf38764c4b", "--accessToken", "0",
        "--versionType", "SimpleShaderPreview", "--width", str(width), "--height", str(height),
        "--quickPlaySingleplayer", "ShaderPreview",
        "--tweakClass", "optifine.OptiFineTweaker", "--launchTarget", "forge_client",
    ]
    if scenes:
        arguments.insert(1, "-Dsimpleshader.preview.scenes=" + ",".join(scenes))
    environment = os.environ.copy()
    environment.pop("DYLD_FRAMEWORK_PATH", None)
    environment["DYLD_INSERT_LIBRARIES"] = runtime["wrapper"]
    environment["TRACE_FILE"] = str(trace)
    log = captures / "capture.log"
    print(f"Capture log: {log}", flush=True)
    with log.open("w") as output:
        result = subprocess.run(arguments, cwd=game_directory, env=environment,
                                stdout=output, stderr=subprocess.STDOUT, timeout=650)
    if result.returncode != 0:
        raise RuntimeError(f"Minecraft capture failed ({result.returncode}); inspect {log}")
    screenshots = sorted((game_directory / "screenshots").glob("*.png"))
    from .replay import SCENES
    expected = scenes or SCENES
    if len(screenshots) != len(expected):
        raise RuntimeError(f"Expected {len(expected)} scene baselines; got {len(screenshots)}")
    print(f"Captured {len(screenshots)} baselines and {trace.stat().st_size:,} trace bytes")
