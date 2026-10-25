#!/usr/bin/env python3
"""Fixed-scene shader previews using real Minecraft GPU recordings.

Setup/capture prepare the local tools and scene data. Render and watch run only
the text converter and OpenGL replay process; neither starts Minecraft.
"""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]

# Keep imaging dependencies isolated and make the everyday command convenient.
environment_python = ROOT / ".preview" / "venv" / "bin" / "python"
if len(sys.argv) > 1 and sys.argv[1] != "setup" and environment_python.exists():
    if Path(sys.prefix).resolve() != environment_python.parent.parent.resolve():
        os.execv(str(environment_python), [str(environment_python), str(Path(__file__).resolve()), *sys.argv[1:]])

from preview.minecraft import capture
from preview.replay import SCENES, index_capture, render
from preview.runtime import probe, setup
from preview.source import build_converter, digest


def settings(name):
    """Load generated local metadata and give an actionable prerequisite error."""
    file = ROOT / ".preview" / f"{name}.json"
    if not file.exists():
        prerequisite = "setup" if name == "runtime" else "capture"
        raise RuntimeError(f"Missing {file.name}; run python3 tools/preview.py {prerequisite}")
    return json.loads(file.read_text())


def archive_capture():
    """Preserve an old capture before rebuilding the isolated scene directory."""
    work = ROOT / ".preview"
    archive = work / "archive" / datetime.now().strftime("%Y%m%d-%H%M%S")
    archive.mkdir(parents=True, exist_ok=True)
    for name in ("game", "captures", "manifest.json", "capture.json"):
        original = work / name
        if original.exists():
            shutil.move(str(original), str(archive / name))
    print(f"Previous capture preserved: {archive}")


def verify(runtime, converter):
    """Verify baseline equality, real fragment/vertex changes and rejection paths."""
    probe(ROOT, runtime)
    work = ROOT / ".preview" / "verification"
    captured_shaders = ROOT / ".preview" / "game" / "shaderpacks" / "SimpleShader" / "shaders"
    baseline = render(ROOT, runtime, converter, shader_root=captured_shaders, output=work / "baseline")
    if any(scene["changed_pixels"] for scene in baseline["scenes"]):
        raise RuntimeError("Unmodified replay does not match every captured baseline")
    results = {"baseline_equal": True}
    def editable_program(folder, name):
        """Variants edit the shared body when dimension wrappers are present."""
        shared = folder / "program" / (name + ".glsl")
        return shared if shared.exists() else folder / name

    cases = (
        ("fragment", "final.fsh", "gl_FragData[0] = vec4(color, 1.0);",
         "gl_FragData[0] = vec4(color * vec3(0.7, 1.0, 0.7), 1.0);", "daylight"),
        ("vertex", "gbuffers_water.vsh",
         "displacedPosition.y += getWaterWaveHeight(worldXZ, frameTimeCounter);",
         "displacedPosition.y += 4.0 * getWaterWaveHeight(worldXZ, frameTimeCounter);", "water"),
    )
    for name, file, before, after, scene_name in cases:
        shaders = work / f"{name}-shaders"
        shutil.copytree(ROOT / "shaders", shaders, dirs_exist_ok=True)
        source = editable_program(shaders, file)
        text = source.read_text()
        if before not in text:
            raise RuntimeError(f"Verification edit no longer applies: {file}")
        source.write_text(text.replace(before, after, 1))
        report = render(ROOT, runtime, converter, names=[scene_name],
                        shader_root=shaders, output=work / name)
        changed = report["scenes"][0]["changed_pixels"]
        if changed == 0 or report["replaced_programs"] == 0:
            raise RuntimeError(f"{name} shader edit did not change actual GPU output")
        results[f"{name}_changed_pixels"] = changed

    invalid = work / "invalid-shaders"
    shutil.copytree(ROOT / "shaders", invalid, dirs_exist_ok=True)
    source = editable_program(invalid, "final.fsh")
    source.write_text(source.read_text().replace(
        "gl_FragData[0] = vec4(color, 1.0);", "gl_FragData[0] = vec4(undefined_preview_symbol);", 1))
    try:
        render(ROOT, runtime, converter, names=["daylight"],
               shader_root=invalid, output=work / "invalid")
    except RuntimeError as error:
        if "GPU replay failed" not in str(error):
            raise
        results["compile_failure_rejected"] = True
    else:
        raise RuntimeError("Invalid shader compilation was not rejected")

    unsupported = work / "unsupported-shaders"
    shutil.copytree(ROOT / "shaders", unsupported, dirs_exist_ok=True)
    source = unsupported / "settings.glsl"
    source.write_text(source.read_text().replace(
        "const int shadowMapResolution = 2048;", "const int shadowMapResolution = 1024;", 1))
    try:
        render(ROOT, runtime, converter, names=["daylight"], shader_root=unsupported,
               output=work / "unsupported")
    except RuntimeError as error:
        if "Loader-owned configuration changed" not in str(error):
            raise
        results["configuration_change_rejected"] = True
    else:
        raise RuntimeError("Changed shadow configuration was not rejected")

    # Compare real GPU output at three opacity levels, including the sky behind.
    from PIL import Image, ImageChops, ImageStat

    cloud_images = {
        "default": Image.open(work / "baseline" / "clouds.png").convert("RGB")
    }
    for name, opacity in (("off", "0.0"), ("dense", "0.95")):
        shaders = work / f"cloud-{name}-shaders"
        shutil.copytree(ROOT / "shaders", shaders, dirs_exist_ok=True)
        source = shaders / "settings.glsl"
        text = source.read_text()
        if "#define CLOUD_OPACITY 0.65" not in text:
            raise RuntimeError("Cloud verification expects the default opacity of 0.65")
        source.write_text(text.replace("#define CLOUD_OPACITY 0.65", f"#define CLOUD_OPACITY {opacity}", 1))
        output = work / f"cloud-{name}"
        render(ROOT, runtime, converter, names=["clouds"], shader_root=shaders, output=output)
        cloud_images[name] = Image.open(output / "clouds.png").convert("RGB")
    cloud_changes = {}
    for name in ("default", "dense"):
        difference = ImageChops.difference(cloud_images["off"], cloud_images[name])
        cloud_changes[name] = sum(ImageStat.Stat(difference).mean) / 3
    if not cloud_changes["dense"] > cloud_changes["default"] > 1.0:
        raise RuntimeError("Cloud visibility or semi-transparency verification failed")
    results["cloud_visible"] = True
    results["cloud_semi_transparency_verified"] = True
    (work / "verification.json").write_text(json.dumps(results, indent=2))
    print(json.dumps(results))


def watch(runtime, converter, names):
    """Re-render after source content changes; keep failed runs visibly failed."""
    previous = None
    print("Watching shaders/; press Ctrl+C to stop", flush=True)
    while True:
        current = tuple((str(file), digest(file)) for file in sorted((ROOT / "shaders").rglob("*")) if file.is_file())
        if current != previous:
            previous = current
            try:
                render(ROOT, runtime, converter, names=names)
            except (RuntimeError, subprocess.CalledProcessError) as error:
                (ROOT / ".preview" / "latest" / "failure.txt").parent.mkdir(parents=True, exist_ok=True)
                (ROOT / ".preview" / "latest" / "failure.txt").write_text(str(error))
                print(f"Preview failed: {error}", file=sys.stderr, flush=True)
        time.sleep(1)


def main():
    """Dispatch the repeatable capture, replay and verification workflow."""
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("setup", help="Build the pinned local tool runtime")
    subcommands.add_parser("probe", help="Check OpenGL capture and shader replacement")
    capture_parser = subcommands.add_parser("capture", help="Prepare real Minecraft scene recordings")
    capture_parser.add_argument("--instance", type=Path,
                                default=Path.home() / "minecraft/versions/1.21.11-Forge-OptiFine")
    capture_parser.add_argument("--world", default="新的世界")
    capture_parser.add_argument("--java-home", type=Path)
    capture_parser.add_argument("--width", type=int, default=960, help="Logical window width before display scaling")
    capture_parser.add_argument("--height", type=int, default=540, help="Logical window height before display scaling")
    capture_parser.add_argument("--render-distance", type=int, default=6)
    capture_parser.add_argument("--shader-dir", type=Path, help="Capture a prepared shader variant")
    capture_parser.add_argument("--scene", action="append", choices=SCENES)
    capture_parser.add_argument("--refresh", action="store_true", help="Archive the existing capture before replacing it")
    capture_parser.add_argument("--native-only", action="store_true", help="Capture client screenshots without the optional GPU recorder")
    capture_parser.add_argument("--prefer-discrete-gpu", action="store_true",
                                help="Temporarily select Windows high-performance graphics for Java")
    selection = capture_parser.add_mutually_exclusive_group()
    selection.add_argument("--companion-jar", type=Path, help="Capture with an explicit companion build")
    selection.add_argument("--without-companion", action="store_true", help="Remove and reject lighting Mods in the isolated target")
    capture_parser.add_argument("--migration-probe", action="store_true", help="Read the isolated platform probe textures")
    capture_parser.add_argument("--run-name", help="Named isolated native capture, e.g. reference or target")
    capture_parser.add_argument("--world-dir", type=Path, help="Frozen save directory to clone")
    capture_parser.add_argument("--settings-dir", type=Path, help="Frozen instance options directory")
    capture_parser.add_argument("--fps-limit", type=int, default=10, help="Isolated client FPS cap; use 120 for throughput tests")
    capture_parser.add_argument("--flight-recording", type=Path, help="Write a Java Flight Recorder profile of the isolated client")
    subcommands.add_parser("index", help="Validate the loader converter and index an existing capture")
    subcommands.add_parser("verify", help="Run actual GPU baseline and shader-edit checks")
    subcommands.add_parser("verify-water", help="Check local water lighting, reflections, waves and roughness")
    subcommands.add_parser("verify-materials", help="Check water controls, refraction, turbidity and local lighting")
    subcommands.add_parser("verify-wind", help="Check foliage roots, seams, normals, motion and shadow matching")
    subcommands.add_parser("verify-underwater", help="Check depth attenuation, surface optics, local emitters and sky gaps")
    subcommands.add_parser("verify-lighting", help="Check night clouds, non-emissive models and local shadow fill")
    subcommands.add_parser("verify-sky", help="Check silhouette leakage and bounded sun/moon discs")
    subcommands.add_parser("verify-air", help="Check shadowed sunlight scattering and bounded indoor/night behaviour")
    subcommands.add_parser("verify-colour", help="Check emitter hues, multilayer glass, panes and coloured sunlight")
    subcommands.add_parser("verify-colour-origin", help="Check rebased camera origins at positive/negative world coordinates")
    subcommands.add_parser("verify-colour-range", help="Check distant light hues, live updates and glass sky visibility")
    subcommands.add_parser("verify-scale", help="Check render-quality framing and final-pass UV readbacks")
    for command in ("render", "watch"):
        child = subcommands.add_parser(command)
        child.add_argument("--scene", action="append", choices=SCENES)
        if command == "render":
            child.add_argument("--shader-dir", type=Path)
            child.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    if arguments.command == "setup":
        setup(ROOT)
        return
    runtime = None if getattr(arguments, 'native_only', False) else settings("runtime")
    if arguments.command == "probe":
        probe(ROOT, runtime)
        return
    if arguments.command == "capture":
        if arguments.run_name and not arguments.native_only:
            parser.error("--run-name currently requires --native-only; replay needs its own fresh index")
        if arguments.run_name and arguments.refresh:
            parser.error("Named captures preserve their own runs; do not use --refresh")
        if arguments.refresh:
            archive_capture()
        java_home = arguments.java_home
        if java_home is None:
            java_home = Path(subprocess.check_output(["/usr/libexec/java_home"], text=True).strip())
        instance = arguments.instance.expanduser().resolve()
        java_home = java_home.expanduser().resolve()
        capture(ROOT, runtime, instance, arguments.world, java_home, scenes=arguments.scene,
                width=arguments.width, height=arguments.height, render_distance=arguments.render_distance,
                shader_root=arguments.shader_dir, companion_jar=arguments.companion_jar,
                fps_limit=arguments.fps_limit, flight_recording=arguments.flight_recording,
                without_companion=arguments.without_companion, run_name=arguments.run_name,
                world_directory=arguments.world_dir, settings_directory=arguments.settings_dir,
                migration_probe=arguments.migration_probe,
                prefer_discrete_gpu=arguments.prefer_discrete_gpu)
        metadata = {"instance": str(instance), "java_home": str(java_home), "world": arguments.world,
                    "scenes": [name for name in SCENES if not arguments.scene or name in arguments.scene],
                    "logical_size": [arguments.width, arguments.height],
                    "render_distance": arguments.render_distance, "fps_limit": arguments.fps_limit,
                    "without_companion": arguments.without_companion, "run_name": arguments.run_name}
        if arguments.flight_recording:
            metadata["flight_recording"] = str(arguments.flight_recording.expanduser().resolve())
        (ROOT / ".preview" / ("capture-" + arguments.run_name + ".json" if arguments.run_name else "capture.json")).write_text(json.dumps(metadata, indent=2))
        if arguments.native_only:
            return
        converter = build_converter(ROOT, instance, java_home)
        index_capture(ROOT, runtime, converter)
        render(ROOT, runtime, converter, shader_root=arguments.shader_dir)
        return
    converter = settings("converter")
    if arguments.command == "index":
        index_capture(ROOT, runtime, converter)
    elif arguments.command == "verify":
        verify(runtime, converter)
    elif arguments.command == "verify-water":
        from preview.water_checks import verify_water
        verify_water(ROOT, runtime, converter)
    elif arguments.command == "verify-materials":
        from preview.material_checks import verify_materials
        verify_materials(ROOT, runtime, converter)
    elif arguments.command == "verify-wind":
        from preview.wind_checks import verify_wind
        verify_wind(ROOT, runtime, converter)
    elif arguments.command == "verify-underwater":
        from preview.underwater_checks import verify_underwater
        verify_underwater(ROOT, runtime, converter)
    elif arguments.command == "verify-lighting":
        from preview.lighting_checks import verify_lighting
        verify_lighting(ROOT, runtime, converter)
    elif arguments.command == "verify-air":
        from preview.air_checks import verify_air
        verify_air(ROOT, runtime, converter)
    elif arguments.command == "verify-colour":
        from preview.colour_checks import verify_colour
        verify_colour(ROOT)
    elif arguments.command == "verify-scale":
        from preview.scale_checks import verify_scale
        print(json.dumps(verify_scale(ROOT, check_uv=True)))
    elif arguments.command == "verify-colour-range":
        from preview.colour_checks import verify_colour_range
        print(json.dumps(verify_colour_range(ROOT)))
    elif arguments.command == "verify-colour-origin":
        from preview.colour_checks import verify_colour_origin
        verify_colour_origin(ROOT)
    elif arguments.command == "verify-sky":
        from preview.sky_checks import verify_sky
        verify_sky(ROOT, runtime, converter)
    elif arguments.command == "render":
        render(ROOT, runtime, converter, names=arguments.scene,
               shader_root=arguments.shader_dir, output=arguments.output)
    elif arguments.command == "watch":
        watch(runtime, converter, arguments.scene)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except subprocess.CalledProcessError as error:
        print(f"Command failed: {error}", file=sys.stderr)
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Preview failed: {error}", file=sys.stderr)
        sys.exit(1)
