"""Launch the installed Forge/OptiFine client in an isolated capture directory.

The original world is copied before any test commands run. Existing local
libraries and assets are reused; launcher credentials are neither read nor sent.
"""

import json
from contextlib import contextmanager
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import zipfile


@contextmanager
def capture_gpu_preference(executable, enabled):
    """Select Windows high-performance graphics for this capture, then restore it.

    Only the exact Java executable's user preference is changed. Existing values
    and types are restored even if launch, shader compilation or capture fails.
    The actual OpenGL renderer must still be verified in the client log.
    """
    if not enabled:
        yield
        return
    if platform.system() != "Windows":
        raise ValueError("Discrete GPU selection is a Windows capture option")
    import winreg

    key_path = r"Software\Microsoft\DirectX\UserGpuPreferences"
    name = str(Path(executable).resolve())
    with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, key_path, 0,
                            winreg.KEY_QUERY_VALUE | winreg.KEY_SET_VALUE) as key:
        try:
            previous = winreg.QueryValueEx(key, name)
        except FileNotFoundError:
            previous = None
        value = previous[0] if previous and previous[1] == winreg.REG_SZ else ""
        fields = [field for field in value.split(";") if field and not field.startswith("GpuPreference=")]
        fields.append("GpuPreference=2")
        winreg.SetValueEx(key, name, 0, winreg.REG_SZ, ";".join(fields) + ";")
        try:
            yield
        finally:
            if previous is None:
                winreg.DeleteValue(key, name)
            else:
                winreg.SetValueEx(key, name, 0, previous[1], previous[0])


def library_allowed(library):
    """Apply the installed version's platform rules to a library entry."""
    rules = library.get("rules")
    if not rules:
        return True
    allowed = False
    os_name = {"Windows": "windows", "Linux": "linux", "Darwin": "osx"}[platform.system()]
    architecture = platform.machine().lower()
    for rule in rules:
        specification = rule.get("os", {})
        if specification.get("name", os_name) not in (os_name, "universal"):
            continue
        required_arch = specification.get("arch")
        if required_arch and not re.fullmatch(required_arch, architecture):
            continue
        os_version = specification.get("version")
        if os_version and not re.search(os_version, platform.version()):
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


def companion_mods(directory):
    """Identify the lighting Mod by metadata, including arbitrarily renamed JARs."""
    result = []
    for file in sorted(directory.glob("*.jar")):
        try:
            with zipfile.ZipFile(file) as archive:
                name = "META-INF/mods.toml"
                metadata = archive.read(name).decode() if name in archive.namelist() else ""
        except (OSError, zipfile.BadZipFile) as error:
            raise RuntimeError(f"Cannot audit isolated Mod: {file}") from error
        if re.search(r'modId\s*=\s*[\"\']simpleshader_lighting[\"\']', metadata):
            result.append(file)
        elif file.name.lower().startswith("simpleshaderlighting"):
            result.append(file)
    return result


def configure_companion(root, game_directory, companion_jar, without_companion):
    """Only isolated test directories may remove stale lighting JARs."""
    if not game_directory.resolve().is_relative_to((root / ".preview").resolve()):
        raise ValueError("Companion selection is limited to the isolated preview directory")
    directory = game_directory / "mods"
    directory.mkdir(parents=True, exist_ok=True)
    for old in companion_mods(directory):
        old.unlink()
    if without_companion:
        if companion_jar is not None:
            raise ValueError("A no-companion capture cannot install a companion JAR")
        assert not companion_mods(directory), "Lighting Mod survived no-companion isolation"
        return None
    release = (root / "VERSION").read_text().strip()
    source = Path(companion_jar) if companion_jar else root / "dist" / f"SimpleShaderLighting-{release}.jar"
    if source.exists():
        target = directory / source.name
        shutil.copy2(source, target)
        return target
    return None


def capture(root, runtime, source_instance, source_world, java_home, scenes=None,
            width=960, height=540, render_distance=6, shader_root=None, companion_jar=None,
            fps_limit=10, flight_recording=None, without_companion=False, run_name=None,
            world_directory=None, settings_directory=None, migration_probe=False,
            prefer_discrete_gpu=False):
    """Capture the fixed real client scenes, leaving the source instance untouched."""
    if platform.system() not in ("Windows", "Darwin"):
        raise RuntimeError("Native capture requires an installed Windows client.")
    if platform.system() == "Windows" and runtime is not None:
        raise ValueError("The CGL recording wrapper cannot be used on Windows")
    if not 1 <= fps_limit <= 260:
        raise ValueError('FPS limit must be between 1 and 260')
    source_instance = Path(source_instance).expanduser().resolve()
    java_home = Path(java_home).expanduser().resolve()
    game_root = source_instance.parent.parent
    version = load_version(source_instance)
    cp = classpath(game_root, version)
    if run_name is not None and not re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", run_name):
        raise ValueError("Invalid capture run name")
    suffix = "-" + run_name if run_name else ""
    captures = root / ".preview" / ("captures" + suffix)
    trace = captures / "minecraft.trace"
    if trace.exists():
        raise RuntimeError(f"Capture already exists; use capture --refresh to preserve and replace it: {trace}")
    game_directory = root / ".preview" / ("game" + suffix)
    game_directory.mkdir(parents=True, exist_ok=True)
    # Interposed CGL calls can race Forge's early-window hand-off on macOS.
    # Only the isolated preview config is changed; Minecraft creates its normal
    # game window and the source instance keeps its existing Forge settings.
    forge_config = game_directory / "config" / "fml.toml"
    forge_config.parent.mkdir(parents=True, exist_ok=True)
    lines = forge_config.read_text().splitlines() if forge_config.exists() else []
    lines = [line for line in lines if not line.strip().startswith("earlyWindowControl")]
    # Windows uses Forge's normal early GL initialization, matching HMCL.
    # Disabling it is only needed for the historical CGL recorder.
    if platform.system() == "Darwin":
        lines.append("earlyWindowControl = false")
    forge_config.write_text("\n".join(lines) + "\n")
    world = game_directory / "saves" / "ShaderPreview"
    if not world.exists():
        shutil.copytree(world_directory or source_instance / "saves" / source_world, world)
    for name in ("options.txt", "optionsof.txt", "optionsshaders.txt"):
        source = (settings_directory or source_instance) / name
        if source.exists():
            shutil.copy2(source, game_directory / name)
    update_options(game_directory / "options.txt", {
        "enableVsync": "false", "maxFps": str(fps_limit), "fullscreen": "false",
        "inactivityFpsLimit": '"minimized"',
        "pauseOnLostFocus": "false", "renderDistance": str(render_distance),
        "simulationDistance": "5", "resourcePacks": "[]",
        "fovEffectScale": "0.0", "bobView": "false",
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
    installed = configure_companion(root, game_directory, companion_jar, without_companion)
    if settings_directory:
        options = settings_directory / "shaderpacks" / "SimpleShader.txt"
        if options.exists():
            shutil.copy2(options, game_directory / "shaderpacks" / "SimpleShader.txt")
    captures.mkdir(parents=True, exist_ok=True)
    # Every run has its own immutable screenshots; never count stale PNG files.
    screenshots = game_directory / "screenshots"
    if screenshots.exists() and any(screenshots.iterdir()):
        previous = captures / "previous-screens"
        number = 0
        while previous.exists():
            number += 1
            previous = captures / f"previous-screens-{number}"
        shutil.move(str(screenshots), previous)
    (captures / "isolation.json").write_text(json.dumps({
        "without_companion": without_companion,
        "companion_jar": str(installed) if installed else None,
        "mods": [file.name for file in (game_directory / "mods").glob("*.jar")],
        "world_source": str(world_directory or source_instance / "saves" / source_world),
    }, indent=2) + "\n")

    native_name = "natives-windows-x86_64" if platform.system() == "Windows" else "natives-macos-arm64"
    natives = source_instance / native_name
    if not natives.is_dir():
        raise RuntimeError(f"Installed native libraries are missing: {natives}")
    captures.mkdir(parents=True, exist_ok=True)
    # Match HMCL's Windows executable selection. Hybrid laptops can assign
    # different GPUs to java.exe and javaw.exe; the capture log is authoritative.
    java_executable = "javaw.exe" if platform.system() == "Windows" else "java"
    arguments = [
        str(java_home / "bin" / java_executable), "-Xmx3G",
        "-Dshaders.debug.save=true", f"-Djava.library.path={natives}",
        f"-Dsimpleshader.preview.width={width}", f"-Dsimpleshader.preview.height={height}",
        f"-Dsimpleshader.preview.fps={fps_limit}",
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
    if platform.system() == "Darwin":
        arguments.insert(1, "-XstartOnFirstThread")
    if migration_probe:
        arguments.insert(1, "-Dsimpleshader.preview.migrationProbe=true")
    if without_companion:
        arguments.insert(1, "-Dsimpleshader.preview.withoutCompanion=true")
    if scenes:
        arguments.insert(1, "-Dsimpleshader.preview.scenes=" + ",".join(scenes))
    if flight_recording:
        recording = Path(flight_recording).expanduser().resolve()
        recording.parent.mkdir(parents=True, exist_ok=True)
        arguments.insert(1, f'-XX:StartFlightRecording=filename={recording},settings=profile,dumponexit=true')
    environment = os.environ.copy()
    environment.pop("DYLD_FRAMEWORK_PATH", None)
    if runtime is not None:
        environment["DYLD_INSERT_LIBRARIES"] = runtime["wrapper"]
        environment["TRACE_FILE"] = str(trace)
    log = captures / "capture.log"
    print(f"Capture log: {log}", flush=True)
    with capture_gpu_preference(arguments[0], prefer_discrete_gpu):
        with log.open("w") as output:
            result = subprocess.run(arguments, cwd=game_directory, env=environment,
                                    stdout=output, stderr=subprocess.STDOUT, timeout=650)
    if result.returncode != 0:
        raise RuntimeError(f"Minecraft capture failed ({result.returncode}); inspect {log}")
    capture_log = log.read_text(errors="replace")
    if without_companion and "SIMPLE_LIGHTING companion loaded" in capture_log:
        raise RuntimeError("Lighting Mod loaded in the no-companion target")
    shader_failures = ("[Shaders] Error loading", "Error compiling", "Error linking", "Invalid program")
    if any(message in capture_log for message in shader_failures):
        raise RuntimeError("Shader loading failed during capture; inspect " + str(log))
    if "SIMPLE_PREVIEW failed" in capture_log or "SIMPLE_PREVIEW complete" not in capture_log:
        raise RuntimeError("Native helper did not complete successfully; inspect " + str(log))
    screenshots = sorted((game_directory / "screenshots").glob("*.png"))
    from .replay import SCENES
    expected = scenes or SCENES
    main_frames = [file for file in screenshots if file.stem in expected]
    missing = sorted(set(expected) - {file.stem for file in main_frames})
    if missing:
        raise RuntimeError(f"Missing {len(missing)} native scene baselines: {', '.join(missing)}")
    if runtime is None:
        print(f"Captured {len(main_frames)} native baselines without GPU recording")
    else:
        print(f"Captured {len(screenshots)} baselines and {trace.stat().st_size:,} trace bytes")
